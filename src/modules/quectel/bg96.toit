// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import log
import uart

import .quectel

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

main:
  service := BG96Service
  service.install

// --------------------------------------------------------------------------

class BG96Service extends CellularServiceProvider:
  constructor:
    super "quectel/bg96" --major=0 --minor=1 --patch=0

  create_driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud_rates/List?:
    return BG96 port logger
        --pwrkey=power
        --rstkey=reset
        --baud_rates=baud_rates
        --is_always_online=true

/**
Driver for BG96, LTE-M modem.
*/
class BG96 extends QuectelCellular:
  pwrkey/gpio.Pin?
  rstkey/gpio.Pin?

  constructor port/uart.Port logger/log.Logger --.pwrkey=null --.rstkey=null --baud_rates/List? --is_always_online/bool:
    super port
        --logger=logger
        --uart_baud_rates=baud_rates or [921_600, cellular.Cellular.DEFAULT_BAUD_RATE]
        --use_psm=not is_always_online

  network_name -> string:
    return "cellular:bg96"

  on_connected_ session/at.Session:
    // Attach to network.
    session.set "+QICSGP" [cid_]
    session.set "+QIACT" [cid_]

  on_reset session/at.Session:
    session.set "+CFUN" [1, 1]

  power_on -> none:
    if not pwrkey: return
    critical_do --no-respect_deadline:
      pwrkey.set 1
      sleep --ms=150
      pwrkey.set 0

  power_off -> none:
    if not pwrkey: return
    critical_do --no-respect_deadline:
      pwrkey.set 1
      sleep --ms=650
      pwrkey.set 0

  reset -> none:
    if not rstkey: return
    critical_do --no-respect_deadline:
      rstkey.set 1
      sleep --ms=150
      rstkey.set 0

  recover_modem -> none:
    if rstkey:
      reset
    else:
      power_off
