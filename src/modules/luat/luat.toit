// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log
import monitor
import uart

import ...base.at as at
import ...base.base
import ...base.cellular
import ...base.cip show CipCellular

/**
Base driver for Luat (AirM2M) LTE Cat-1 modules.

The bulk of the SIMCom-style multi-IP AT command flow lives in $CipCellular.
  $LuatCellular layers in the LTE-aware bits: registration through both
  +CEREG and +CGREG, AT+COPS=0 without format parameter, AT+CFUN=4 (airplane
  mode) for the radio-off transition so the SIM stays accessible, and an
  effective-APN that falls back to CGDCONT for auto-APN SIMs.
*/
abstract class LuatCellular extends CipCellular:
  constructor
      uart/uart.Port
      --logger/log.Logger
      --uart-baud-rates/List
      --use-psm/bool:
    super uart
        --logger=logger
        --uart-baud-rates=uart-baud-rates
        --use-psm=use-psm

  /**
  Sends AT+CFUN=4 (airplane mode) instead of AT+CFUN=0. On the Air780E,
    CFUN=0 disables the SIM interface entirely ("ue not power on"), causing
    subsequent CPIN reads to fail for the duration of the configuration.
  */
  disable-radio_ session/at.Session:
    session.send CFUN.airplane

  /**
  Registers through both LTE (+CEREG) and GSM (+CGREG), and uses a custom
    AT+COPS=0 (no format parameter) — the Air780E rejects "AT+COPS=0,2"
    with "Incorrect parameters".
  */
  connect_ session/at.Session --operator/Operator?=null --psm/bool -> none:
    if operator or psm:
      super session --operator=operator --psm=psm
      return
    failed-to-connect = true
    is-lte-connection_ = false

    done := monitor.Latch
    registrations := { "+CEREG", "+CGREG" }
    failed := {}

    registrations.do: | command/string |
      session.register-urc command:: | args |
        state := args.first
        if state == 1 or state == 5:
          failed.remove command
          done.set command
        else if state == 3 or state == 80:
          failed.add command
          error := state == 3 ? REGISTRATION-DENIED-ERROR : "connection lost"
          if failed.size == registrations.size: done.set --exception error

    try:
      registrations.do: session.set it [2]
      send-abortable_ session COPS-AUTOMATIC-NO-FORMAT_
      wait-for-urc_ --session=session:
        if done.get == "+CEREG":
          is-lte-connection_ = true
    finally:
      registrations.do: session.unregister-urc it

    on-connected_ session
    failed-to-connect = false

  /**
  Writes the APN to CGDCONT for the LTE attach, then defers the IP-stack
    setup to $on-connected_ via CSTT/CIICR.
  */
  configure apn/string --bands/List?=null --rats/List?=null:
    apn_ = apn
    at_.do: | session/at.Session |
      // For auto-APN SIMs the caller passes apn="" and CGDCONT is already
      // populated by the SIM/network; only enter the (slower) CFUN=4 dance
      // when the APN actually needs to change.
      if apn == "" or (get-apn_ session) == apn:
        wait-for-sim_ session
        return
      enter-configuration-mode_ session
      set-apn_ session apn

  /**
  Returns the APN for CSTT, falling back to CGDCONT when none was supplied.
    For auto-APN SIMs (e.g., simbase) CGDCONT already has the right value.
  */
  effective-apn_ session/at.Session -> string:
    if not apn_.is-empty: return apn_
    return get-apn_ session

/**
AT+COPS=0 without the numeric-format parameter. The Air780E rejects
  AT+COPS=0,2 with "Incorrect parameters".
*/
COPS-AUTOMATIC-NO-FORMAT_ ::= COPS-NoFormat_

class COPS-NoFormat_ extends at.Command:
  constructor:
    super.set "+COPS" --parameters=[0] --timeout=COPS.compute-timeout
