// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import log
import uart

import .ublox

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

main:
  service := SaraR5Service
  service.install

// --------------------------------------------------------------------------

class SaraR5Service extends CellularServiceProvider:
  constructor:
    super "ublox/sara_r5" --major=0 --minor=1 --patch=0

  create-driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud-rates/List?:
    return SaraR5 port logger
        --rx=rx
        --tx=tx
        --rts=rts
        --cts=cts
        --pwr-on=power
        --reset-n=reset
        --uart-baud-rates=baud-rates or [921_600, cellular.Cellular.DEFAULT-BAUD-RATE]
        --is-always-online=true

/**
Driver for Sara-R5, GSM communicating over NB-IoT & M1.
*/
class SaraR5 extends UBloxCellular:
  static CONFIG_ ::= {:}

  rx/gpio.Pin?
  tx/gpio.Pin?
  rts/gpio.Pin?
  cts/gpio.Pin?
  pwr-on/gpio.Pin?
  reset-n/gpio.Pin?

  constructor port/uart.Port logger/log.Logger
      --.rx=null
      --.tx=null
      --.rts=null
      --.cts=null
      --.pwr-on=null
      --.reset-n=null
      --uart-baud-rates/List
      --is-always-online/bool:
    super
      port
      --logger=logger
      --config=CONFIG_
      --cat-m1
      --uart-baud-rates=uart-baud-rates
      --use-psm=not is-always-online

  network-name -> string:
    return "cellular:sara-r5"

  static list-equals_ a/List b/List -> bool:
    if a.size != b.size: return false
    a.size.repeat:
      if a[it] != b[it]: return false
    return true

  on-connected_ session/at.Session:
    upsd-status := session.set "+UPSND" [0, 8]
    if list-equals_ upsd-status.last [0, 8, 1]:
      // The PDP profile is already active. Trying to change it is
      // an illegal operation at this point.
      return

    // Attach to network.
    changed := false
    upsd-map-cid-target := [0, 100, 1]
    upsd-map-cid := session.set "+UPSD" upsd-map-cid-target[0..2]
    if not list-equals_ upsd-map-cid.last upsd-map-cid-target:
      session.set "+UPSD" upsd-map-cid-target
      changed = true

    upsd-protocol-target := [0, 0, 0]
    upsd-protocol := session.set "+UPSD" upsd-protocol-target[0..2]
    if not list-equals_ upsd-protocol.last upsd-protocol-target:
      session.set "+UPSD" upsd-protocol-target
      changed = true

    if changed:
      send-abortable_ session (UPSDA --action=0)
      send-abortable_ session (UPSDA --action=3)

  psm-enabled-psv-target -> List:
    return [1, 2000]  // TODO(kasper): Testing - go to sleep after ~9.2s.

  reboot-after-cedrxs-or-cpsms-changes -> bool:
    return false

  on-reset session/at.Session:
    session.send
      cellular.CFUN.reset --reset-sim

  power-on -> none:
    if not pwr-on: return
    critical-do --no-respect-deadline:
      pwr-on.set 1
      sleep --ms=1000
      pwr-on.set 0
      // TODO(kasper): We try to wait for a bit like we do on
      // the SaraR4. It isn't clear if this is necessary.
      sleep --ms=250

  power-off -> none:
    if not (pwr-on and reset-n): return
    critical-do --no-respect-deadline:
      pwr-on.set 1
      reset-n.set 1
      sleep --ms=23_100  // Minimum is 23,000 ms.
      pwr-on.set 0
      sleep --ms=1_600   // Minimum is 1,500 ms.
      reset-n.set 0

  reset -> none:
    if not reset-n: return
    critical-do --no-respect-deadline:
      reset-n.set 1
      sleep --ms=150  // Minimum is 100ms.
      reset-n.set 0
      sleep --ms=250  // Wait like we do in $power_on.

  is-powered-off -> bool?:
    if rx == null: return null

    // On SARA-R5, the RXD pin (modem's uart output) is a push-pull
    // pin which is idle high and active low. When the modem is
    // powered up, this pin will be connected to the internal 1.8V
    // rail, which is turned off during power down. Therefore, by
    // momentarily configuring the pin with a pull-down on the host
    // microcontroller, we can assess the modem's state by checking
    // this pin - without waking the modem up again. If the modem is
    // powered up, RX will be high, and if it's powered down, it will
    // be low (ensured by the pull-down).

    rx.configure --input --pull-down

    // Run multiple checks of the pin state to ensure that it's not flickering.
    all-low := true
    8.repeat:
      if all-low and rx.get == 1: all-low = false

    // Reconfigure the RX pin as normal input.
    rx.configure --input
    return all-low


class UPSDA extends at.Command:
  // UPSDA times out after 180s, but since it can be aborted, any timeout can be used.
  static MAX-TIMEOUT ::= Duration --m=3

  constructor --action/int:
    super.set "+UPSDA" --parameters=[0, action] --timeout=compute-timeout

  // We use the deadline in the task to let the AT processor know that we can abort
  // the UPSDA operation by sending more AT commands.
  static compute-timeout -> Duration:
    return min MAX-TIMEOUT (Duration --us=(Task.current.deadline - Time.monotonic-us))
