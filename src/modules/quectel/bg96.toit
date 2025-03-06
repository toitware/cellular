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
    return BG96 port logger
        --pwrkey=power
        --rstkey=reset
        --baud-rates=baud-rates
        --is-always-online=true

/**
Driver for BG96, LTE-M modem.
*/
class BG96 extends QuectelCellular:
  pwrkey/gpio.Pin?
  rstkey/gpio.Pin?

  constructor port/uart.Port logger/log.Logger --.pwrkey=null --.rstkey=null --baud-rates/List? --is-always-online/bool:
    super port
        --logger=logger
        --uart-baud-rates=baud-rates or [921_600, cellular.Cellular.DEFAULT-BAUD-RATE]
        --use-psm=not is-always-online

  network-name -> string:
    return "cellular:bg96"

  on-connected_ session/at.Session:
    // Attach to network.
    session.set "+QICSGP" [cid_]
    session.send (QIACT cid_)

  on-reset session/at.Session:
    session.set "+CFUN" [1, 1]

  power-on -> none:
    if not pwrkey: return
    critical-do --no-respect-deadline:
      pwrkey.set 1
      sleep --ms=150
      pwrkey.set 0

  power-off -> none:
    if not pwrkey: return
    critical-do --no-respect-deadline:
      pwrkey.set 1
      sleep --ms=650
      pwrkey.set 0

  reset -> none:
    if not rstkey: return
    critical-do --no-respect-deadline:
      rstkey.set 1
      sleep --ms=150
      rstkey.set 0
