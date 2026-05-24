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
Base driver for SIMCom 2G modules (GSM/GPRS).

The bulk of the SIMCom-style multi-IP AT command flow lives in $CipCellular.
  $SimcomCellular only adds the SIM800L-specific GSM-only registration and
  defers the APN to AT+CSTT in $on-connected_.
*/
abstract class SimcomCellular extends CipCellular:
  abstract on-reset session/at.Session

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
  Overrides the base connect to use only GSM registration commands.
  The SIM800L doesn't support LTE (+CEREG).
  */
  connect_ session/at.Session --operator/Operator?=null --psm/bool -> none:
    failed-to-connect = true

    done := monitor.Latch
    // SIM800L only supports GSM/GPRS, so we use +CGREG (GPRS registration)
    // instead of +CEREG (LTE). See AT Command Manual Section 7.2.10.
    // +CGREG URC states: 1=registered home, 5=registered roaming.
    registrations := { "+CGREG" }
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
      // Enable registration events.
      registrations.do: session.set it [2]

      if not psm:
        command := operator
            ? COPS.manual operator.op --rat=operator.rat
            : COPS.automatic
        send-abortable_ session command

      wait-for-urc_ --session=session:
        done.get

    finally:
      registrations.do: session.unregister-urc it

    on-connected_ session
    failed-to-connect = false

  /**
  Stores the APN for $on-connected_ to feed into AT+CSTT. The SIM800L
    doesn't need CGDCONT; the IP stack receives the APN through CSTT.
  */
  configure apn/string --bands/List?=null --rats/List?=null:
    apn_ = apn
    at_.do: | session/at.Session |
      wait-for-sim_ session
