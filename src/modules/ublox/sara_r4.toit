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
  service := SaraR4Service
  service.install

// --------------------------------------------------------------------------

class SaraR4Service extends CellularServiceProvider:
  constructor:
    super "ublox/sara_r4" --major=0 --minor=1 --patch=0

  create-driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/any
      --tx/any
      --rts/any
      --cts/any
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud-rates/List?:
    return SaraR4 port logger
        --pwr-on=power
        --reset-n=reset
        --uart-baud-rates=baud-rates or [460_800, cellular.Cellular.DEFAULT-BAUD-RATE]
        --is-always-online=true

/**
Driver for Sara-R4, GSM communicating over NB-IoT & M1.
*/
class SaraR4 extends UBloxCellular:
  static CONFIG_ ::= {
    // Disables the TCP socket Graceful Dormant Close feature. With this enabled,
    // the module waits for ack (or timeout) from peer, before closing socket
    // resources.
    "+USOCLCFG": [0],
  }

  rx/any
  tx/any
  rts/any
  cts/any
  pwr-on/gpio.Pin?
  reset-n/gpio.Pin?

  /**
  The $rx, $tx, $rts and $cts pins are GPIO numbers. Passing a $gpio.Pin is
    deprecated; provide the integer GPIO number instead.
  */
  // __TYPE-MIGRATION__ rx: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ rx: int?
  // __TYPE-MIGRATION__ tx: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ tx: int?
  // __TYPE-MIGRATION__ rts: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ rts: int?
  // __TYPE-MIGRATION__ cts: gpio.Pin. Deprecated. Provide an integer instead.
  // __TYPE-MIGRATION__ cts: int?
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
      --cat-nb1
      --uart-baud-rates=uart-baud-rates
      --async-socket-connect
      --async-socket-close
      --use-psm=not is-always-online

  network-name -> string:
    return "cellular:sara-r4"

  on-connected_ session/at.Session:
    // Do nothing.

  psm-enabled-psv-target -> List:
    return [4]

  reboot-after-cedrxs-or-cpsms-changes -> bool:
    return false

  on-reset session/at.Session:
    session.send cellular.CFUN.reset

  power-on -> none:
    if not pwr-on: return
    critical-do --no-respect-deadline:
      pwr-on.set 1
      sleep --ms=150
      pwr-on.set 0
      // The chip needs the pin to be off for 250ms so it doesn't turn off again.
      sleep --ms=250

  power-off -> none:
    if not pwr-on: return
    critical-do --no-respect-deadline:
      pwr-on.set 1
      sleep --ms=1500
      pwr-on.set 0

  reset -> none:
    if not reset-n: return
    critical-do --no-respect-deadline:
      reset-n.set 1
      sleep --ms=10_000
      reset-n.set 0
