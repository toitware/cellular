// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import log
import uart

import .simcom

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

main:
  service := SIM800LService
  service.install

// --------------------------------------------------------------------------

class SIM800LService extends CellularServiceProvider:
  constructor:
    super "simcom/sim800l" --major=0 --minor=1 --patch=0

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
    return SIM800L port logger
        --pwrkey=power
        --rst-pin=reset
        --baud-rates=baud-rates

/**
Driver for SIM800L, GSM/GPRS modem.

The $pwrkey pin corresponds to the PWRKEY pin of the SIM800L module.
The $rst-pin corresponds to the RST pin.
*/
class SIM800L extends SimcomCellular:
  pwrkey/gpio.Pin?
  rst-pin/gpio.Pin?

  constructor port/uart.Port logger/log.Logger
      --.pwrkey=null
      --.rst-pin=null
      --baud-rates/List?:
    super port
        --logger=logger
        --uart-baud-rates=baud-rates or [115_200]
        --use-psm=false

  network-name -> string:
    return "cellular:sim800l"

  on-connected_ session/at.Session:
    // Enable multi-connection mode.
    session.set "+CIPMUX" [1]
    // Enable manual data receive mode.
    session.set "+CIPRXGET" [1]
    // Shut down any previous IP connection.
    session.action "+CIPSHUT"
    // Set APN.
    session.set "+CSTT" [apn_]
    // Bring up wireless connection (GPRS).
    session.action "+CIICR" --timeout=(Duration --s=30)
    // Get local IP address. AT+CIFSR returns just the IP without "OK",
    // so we use a short timeout and accept whatever comes back.
    result := session.action "+CIFSR" --timeout=(Duration --s=5) --no-check
    logger.info "GPRS connected" --tags={"ip": result}

  on-reset session/at.Session:
    session.set "+CFUN" [1, 1]

  powered-on_ := false

  power-on -> none:
    if powered-on_: return
    powered-on_ = true
    // PWRKEY pulse to turn on the module.
    if pwrkey:
      critical-do --no-respect-deadline:
        pwrkey.set 1
        sleep --ms=1100
        pwrkey.set 0
        sleep --ms=3000

  power-off -> none:
    if not pwrkey: return
    // PWRKEY pulse to turn off (hold >650ms).
    critical-do --no-respect-deadline:
      pwrkey.set 1
      sleep --ms=1500
      pwrkey.set 0

  reset -> none:
    if not rst-pin: return
    critical-do --no-respect-deadline:
      rst-pin.set 0
      sleep --ms=150
      rst-pin.set 1
