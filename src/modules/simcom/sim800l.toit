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
  service := Sim800lService
  service.install

// --------------------------------------------------------------------------

class Sim800lService extends CellularServiceProvider:
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
    return Sim800l port logger
        --pwrkey=power
        --rst-pin=reset
        --baud-rates=baud-rates

/**
Driver for SIM800L, GSM/GPRS modem.

The $pwrkey pin corresponds to the PWRKEY pin of the SIM800L module.
The $rst-pin corresponds to the RST pin.
*/
class Sim800l extends SimcomCellular:
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
    // AT Command Manual V1.09, Section 8.2.1 (CIPMUX):
    // AT+CIPMUX=1 enables multi-IP connection (up to 6 connections, IDs 0-5).
    // Must be set when state is IP INITIAL (before CIPSTART).
    session.set "+CIPMUX" [1]
    // AT Command Manual V1.09, Section 8.2.26 (CIPRXGET):
    // AT+CIPRXGET=1 enables manual data receive mode.
    // When data arrives, a "+CIPRXGET: 1,<id>" URC is sent instead of
    // pushing raw data to the serial port. This avoids mixing binary
    // data with AT command responses.
    session.set "+CIPRXGET" [1]
    // AT Command Manual V1.09, Section 8.2.7 (CIPSHUT):
    // Deactivates GPRS PDP context. Resets state to IP INITIAL.
    session.action "+CIPSHUT"
    // AT Command Manual V1.09, Section 8.2.9 (CSTT):
    // AT+CSTT=<apn> starts task and sets APN. Valid only at IP INITIAL state.
    // After this command, state changes to IP START.
    session.set "+CSTT" [apn_]
    // AT Command Manual V1.09, Section 8.2.10 (CIICR):
    // Brings up wireless connection (GPRS or CSD). Max response time: 85s.
    // State changes: IP START -> IP CONFIG -> IP GPRSACT.
    session.action "+CIICR" --timeout=(Duration --s=30)
    // AT Command Manual V1.09, Section 8.2.11 (CIFSR):
    // Gets local IP address. Response is just "<IP address>" without "OK".
    // Only works after PDP context is activated (state IP GPRSACT or later).
    result := session.action "+CIFSR" --timeout=(Duration --s=5) --no-check
    logger.info "GPRS connected" --tags={"ip": result}

  on-reset session/at.Session:
    // AT Command Manual V1.09, Section 3.2.42 (CFUN):
    // AT+CFUN=1,1 sets full functionality and resets the module.
    session.set "+CFUN" [1, 1]

  powered-on_ := false

  power-on -> none:
    if powered-on_: return
    powered-on_ = true
    // SIM800L Hardware Design V1.00:
    // Pull PWRKEY low for at least 1 second to turn on the module.
    // The PWRKEY pin toggles power state (on<->off), so we only
    // pulse it once to avoid turning the module off again.
    if pwrkey:
      critical-do --no-respect-deadline:
        pwrkey.set 1
        sleep --ms=1100
        pwrkey.set 0

  power-off -> none:
    if not pwrkey: return
    // SIM800L Hardware Design V1.00:
    // Pull PWRKEY low for at least 650ms to turn off the module.
    critical-do --no-respect-deadline:
      pwrkey.set 1
      sleep --ms=1500
      pwrkey.set 0

  reset -> none:
    if not rst-pin: return
    // SIM800L Hardware Design V1.00:
    // Pull RST low for at least 105ms to perform a hard reset.
    critical-do --no-respect-deadline:
      rst-pin.set 0
      sleep --ms=150
      rst-pin.set 1
