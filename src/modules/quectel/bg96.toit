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
import ...base.service show LocationServiceProvider
import ...config

main --config/CellularConfiguration=CellularConfiguration:
  service := BG96Service --config=config
  service.install

// --------------------------------------------------------------------------

class BG96Service extends LocationServiceProvider:
  constructor --config/CellularConfiguration:
    super "quectel/bg96" --major=0 --minor=1 --patch=0 --config=config

  create_driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --config/CellularConfiguration:
    return BG96 port logger
        --pwrkey=config.power
        --rstkey=config.reset
        --baud_rates=config.uart-baud-rates
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
    session.send (QNWINFO)
    session.set "+QICSGP" [cid_]
    session.send (QIACT cid_)

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
