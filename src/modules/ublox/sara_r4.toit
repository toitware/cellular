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
import ...config

main --config/CellularConfiguration=CellularConfiguration:
  service := SaraR4Service
  service.install

// --------------------------------------------------------------------------

class SaraR4Service extends CellularServiceProvider:
  constructor --config/CellularConfiguration:
    super "ublox/sara_r4" --major=0 --minor=1 --patch=0 --config=config

  create_driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --config/CellularConfiguration:
    return SaraR4 port logger
        --pwr_on=config.power
        --reset_n=config.reset
        --uart_baud_rates=config.uart-baud-rates or [460_800, cellular.Cellular.DEFAULT_BAUD_RATE]
        --is_always_online=true

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

  rx/gpio.Pin?
  tx/gpio.Pin?
  rts/gpio.Pin?
  cts/gpio.Pin?
  pwr_on/gpio.Pin?
  reset_n/gpio.Pin?

  constructor port/uart.Port logger/log.Logger
      --.rx=null
      --.tx=null
      --.rts=null
      --.cts=null
      --.pwr_on=null
      --.reset_n=null
      --uart_baud_rates/List
      --is_always_online/bool:
    super
      port
      --logger=logger
      --config=CONFIG_
      --cat_m1
      --cat_nb1
      --uart_baud_rates=uart_baud_rates
      --async_socket_connect
      --async_socket_close
      --use_psm=not is_always_online

  network_name -> string:
    return "cellular:sara-r4"

  on_connected_ session/at.Session:
    // Do nothing.

  psm_enabled_psv_target -> List:
    return [4]

  reboot_after_cedrxs_or_cpsms_changes -> bool:
    return false

  on_reset session/at.Session:
    session.send cellular.CFUN.reset

  power_on -> none:
    if not pwr_on: return
    critical_do --no-respect_deadline:
      pwr_on.set 1
      sleep --ms=150
      pwr_on.set 0
      // The chip needs the pin to be off for 250ms so it doesn't turn off again.
      sleep --ms=250

  power_off -> none:
    if not pwr_on: return
    critical_do --no-respect_deadline:
      pwr_on.set 1
      sleep --ms=1500
      pwr_on.set 0

  reset -> none:
    if not reset_n: return
    critical_do --no-respect_deadline:
      reset_n.set 1
      sleep --ms=10_000
      reset_n.set 0
