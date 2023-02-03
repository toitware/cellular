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

  create_driver --port/uart.Port --power/gpio.Pin? --reset/gpio.Pin? -> cellular.Cellular:
    return SaraR5 port
        --logger=create_logger
        --pwr_on=power
        --reset_n=reset
        --is_always_online=true

/**
Driver for Sara-R5, GSM communicating over NB-IoT & M1.
*/
class SaraR5 extends UBloxCellular:
  static CONFIG_ ::= {:}

  pwr_on/gpio.Pin?
  reset_n/gpio.Pin?

  constructor uart/uart.Port --logger=log.default --.pwr_on=null --.reset_n=null --is_always_online/bool:
    super
      uart
      --logger=logger
      --config=CONFIG_
      --cat_m1
      --preferred_baud_rate=921_600
      --use_psm=not is_always_online

  list_equals a/List b/List -> bool:
    if a.size != b.size: return false
    a.size.repeat:
      if a[it] != b[it]: return false
    return true

  on_connected_ session/at.Session:
    upsd_status := session.set "+UPSND" [0, 8]
    if list_equals upsd_status.last [0, 8, 1]:
      // The PDP profile is already active. Trying to change it is
      // an illegal operation at this point.
      return

    // Attach to network.
    changed := false
    upsd_map_cid_target := [0, 100, 1]
    upsd_map_cid := session.set "+UPSD" upsd_map_cid_target[0..2]
    if not list_equals upsd_map_cid.last upsd_map_cid_target:
      session.set "+UPSD" upsd_map_cid_target
      changed = true

    upsd_protocol_target := [0, 0, 0]
    upsd_protocol := session.set "+UPSD" upsd_protocol_target[0..2]
    if not list_equals upsd_protocol.last upsd_protocol_target:
      session.set "+UPSD" upsd_protocol_target
      changed = true

    if changed:
      send_abortable_ session (UPSDA --action=0)
      send_abortable_ session (UPSDA --action=3)

  psm_enabled_psv_target -> List:
    return [1, 2000]  // TODO(kasper): Testing - go to sleep after ~9.2s.

  reboot_after_cedrxs_or_cpsms_changes -> bool:
    return false

  on_reset session/at.Session:
    session.send
      cellular.CFUN.reset --reset_sim

  power_on -> none:
    if not pwr_on: return
    critical_do --no-respect_deadline:
      pwr_on.set 1
      sleep --ms=1000
      pwr_on.set 0
      // TODO(kasper): We try to wait for a bit like we do on
      // the SaraR4. It isn't clear if this is necessary.
      sleep --ms=250

  power_off -> none:
    if not (pwr_on and reset_n): return
    critical_do --no-respect_deadline:
      pwr_on.set 1
      reset_n.set 1
      sleep --ms=23_100  // Minimum is 23,000 ms.
      pwr_on.set 0
      sleep --ms=1_600   // Minimum is 1,500 ms.
      reset_n.set 0

  reset -> none:
    if not reset_n: return
    critical_do --no-respect_deadline:
      reset_n.set 1
      sleep --ms=150  // Minimum is 100ms.
      reset_n.set 0
      sleep --ms=250  // Wait like we do in $power_on.

  // Prefer reset over power_off (100ms vs ~25s).
  recover_modem:
    reset

class UPSDA extends at.Command:
  // UPSDA times out after 180s, but since it can be aborted, any timeout can be used.
  static MAX_TIMEOUT ::= Duration --m=3

  constructor --action/int:
    super.set "+UPSDA" --parameters=[0, action] --timeout=compute_timeout

  // We use the deadline in the task to let the AT processor know that we can abort
  // the UPSDA operation by sending more AT commands.
  static compute_timeout -> Duration:
    return min MAX_TIMEOUT (Duration --us=(Task.current.deadline - Time.monotonic_us))
