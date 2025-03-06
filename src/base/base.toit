// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log
import uart
import net
import monitor

import .at as at
import .cellular
import ..state show SignalQuality

REGISTRATION-DENIED-ERROR ::= "registration denied"

/**
Base functionality of Cellular modems, encapsulating the generic functionality.

Major things that are not implemented in the base is:
  * Chip configurations, e.g. bands and RATs.
  * TCP/UDP/IP stack.
*/
abstract class CellularBase implements Cellular:
  sockets_/Map ::= {:}
  logger/log.Logger
  at-session_/at.Session
  at_/at.Locker

  uart_/uart.Port
  uart-baud-rates/List

  cid_ := 1

  failed-to-connect/bool := false

  constants/Constants

  use-psm/bool := true

  is-lte-connection_ := false

  constructor
      .uart_
      .at-session_
      --.logger
      --.uart-baud-rates
      --.constants
      --.use-psm:
    at_ = at.Locker at-session_

  abstract iccid -> string

  abstract configure apn/string --bands/List?=null --rats=null

  abstract close -> none

  close-uart -> none:
    uart_.close

  support-gsm_ -> bool:
    return false

  model:
    r := at_.do: it.action "+CGMM"
    return r.last.first

  version:
    r := at_.do: it.action "+CGMR"
    return r.last.first

  scan-for-operators -> List:
    operators := []
    at_.do: | session/at.Session |
      result := send-abortable_ session COPS.scan
      operators = result.last

    result := []
    operators.do: | o |
      if o is List and o.size == 5 and o[1] is string and o[0] != 3:  // 3 = operator forbidden.
        rat := o[4] is int ? o[4] : null
        result.add
          Operator o[3] --rat=rat
    return result

  connect-psm -> none:
    at_.do: | session/at.Session |
      connect_ session --operator=null --psm

  connect --operator/Operator?=null -> none:
    at_.do: | session/at.Session |
      connect_ session --operator=operator --no-psm

  // TODO(Lau): Support the other operator formats than numeric.
  get-connected-operator -> Operator?:
    catch --trace:
      at_.do: | session/at.Session |
        res := (send-abortable_ session COPS.read).last
        if res.size == 4 and res[1] == COPS.FORMAT-NUMERIC and res[2] is string and res[2].size == 5:
          return Operator res[2]
    return null

  detach:
    at_.do: | session/at.Session |
      send-abortable_ session COPS.deregister

  signal-strength -> float?:
    quality := signal-quality
    return quality ? quality.power : null

  signal-quality -> SignalQuality?:
    e := catch:
      res := at_.do: it.action "+CSQ"
      values := res.single
      power := values[0]
      power = (power == 99) ? null : power / 31.0
      quality := values[1]
      quality = (quality == 99) ? null : quality / 7.0
      return SignalQuality --power=power --quality=quality
    logger.warn "failed to read signal strength" --tags={"error": "$e"}
    return null

  wait-for-ready:
    at_.do: wait-for-ready_ it

  enable-radio:
    at_.do: | session/at.Session |
      session.send CFUN.online

  disable-radio -> none:
    at_.do: | session/at.Session |
      disable-radio_ session

  disable-radio_ session/at.Session:
    session.send CFUN.offline

  is-radio-enabled_ session/at.Session:
    result := session.send CFUN.get
    return result.single.first == "1"

  get-apn_ session/at.Session:
    ctx := session.read "+CGDCONT"
    ctx.responses.do:
      if it.first == cid_: return it[2]
    return ""

  set-apn_ session/at.Session apn:
    session.set "+CGDCONT" [cid_, "IP", apn]

  wait-for-ready_ session/at.Session:
    while true:
      // We try to power on the modem a number of
      // times (until we run out of time) to improve
      // the robustness of the power on sequence.
      power-on
      if select-baud_ session: break

  enter-configuration-mode_ session/at.Session:
    disable-radio_ session
    wait-for-sim_ session

  select-baud_ session/at.Session --count=5:
    preferred := uart-baud-rates.first
    count.repeat:
      uart-baud-rates.do: | rate |
        uart_.baud-rate = rate
        if is-ready_ session:
          // If the current rate isn't the preferred one, we assume
          // we can change it to the preferred one. If it already is
          // the preferred one, it is enough for us to know that we
          // can talk to the modem using the rate, so we conclude
          // that we correctly configured the rate.
          if rate != preferred:
            set-baud-rate_ session preferred
          return true
    return false

  is-ready_ session/at.Session:
    response := session.action "" --timeout=(Duration --ms=250) --no-check

    if response == null:
      // By sleeping for even a little while here, we get a check for whether or
      // not we're past any deadline set by the caller of this method. The sleep
      // inside the is_ready call isn't enough, because it is wrapped in a catch
      // block. If we're out of time, we will throw a DEADLINE_EXCEEDED exception.
      sleep --ms=10
      return false

    // Wait for data to be flushed.
    sleep --ms=100

    // Disable echo.
    session.action "E0"
    // Verbose errors.
    session.set "+CMEE" [2]
    // TODO(anders): This is where we want to use an optional PIN:
    //   session.set "+CPIN" ["1234"]

    return true

  wait-for-sim_ session/at.Session:
    // Wait up to 10 seconds for the SIM to be initialized.
    40.repeat:
      catch --unwind=(: it == DEADLINE-EXCEEDED-ERROR):
        r := session.read "+CPIN"
        return
      sleep --ms=250

  wait-for-urc_ --session/at.Session?=null [block]:
    while true:
      catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout --ms=1000:
          return block.call
      // Ping every second
      if session: session.action "" --no-check
      else: at_.do: it.action "" --no-check

  connect_ session/at.Session --operator/Operator? --psm/bool -> none:
    failed-to-connect = true
    is-lte-connection_ = false

    done := monitor.Latch
    registrations := { "+CEREG" }
    if support-gsm_: registrations.add "+CGREG"
    failed := {}

    registrations.do: | command/string |
      session.register-urc command::
        state := it.first
        if state == 1 or state == 5:
          failed.remove command
          done.set command
        else if state == 3 or state == 80:
          failed.add command
          error := state == 3 ? REGISTRATION-DENIED-ERROR : "connection lost"
          // If all registrations have failed, we report the last error.
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
        if done.get == "+CGREG":
          is-lte-connection_ = true
          use-psm = false

    finally:
      // TODO(kasper): Should we unregister the interest in the events?
      registrations.do: session.unregister-urc it

    on-connected_ session
    failed-to-connect = false

  send-abortable_ session/at.Session command/at.Command -> at.Result:
    try:
      return session.send command
    finally: | is-exception exception |
      if is-exception and exception.value == at.COMMAND-TIMEOUT-ERROR:
        on-aborted-command session command

  on-aborted-command session/at.Session command/at.Command -> none:
    // Do nothing by default.

  abstract set-baud-rate_ session/at.Session baud-rate/int

  abstract network-name -> string
  abstract network-interface -> net.Interface

  // Dummy implementations.
  power-on -> none:
  power-off -> none:
  reset -> none:
  is-powered-off -> bool?:
    return null

  /**
  Called when the driver has connected.
  */
  abstract on-connected_ session/at.Session

interface Constants:
  RatCatM1 -> int?

class CFUN extends at.Command:
  static TIMEOUT ::= Duration --m=3

  constructor.offline:
    super.set "+CFUN" --parameters=[0] --timeout=TIMEOUT

  constructor.online --reset=false:
    params := [1]
    if reset: params.add 1
    super.set "+CFUN" --parameters=params --timeout=TIMEOUT

  constructor.airplane:
    super.set "+CFUN" --parameters=[4] --timeout=TIMEOUT

  constructor.reset --reset-sim/bool=false:
    super.set "+CFUN" --parameters=[reset-sim ? 16 : 15] --timeout=TIMEOUT

  constructor.get:
    super.read "+CFUN" --timeout=TIMEOUT

class COPS extends at.Command:
  // COPS times out after 180s, but since it can be aborted, any timeout can be used.
  static MAX-TIMEOUT ::= Duration --m=3
  static FORMAT-NUMERIC ::= 2

  constructor.manual operator --rat=null:
    args := [1, FORMAT-NUMERIC, operator]
    if rat: args.add rat
    super.set "+COPS" --parameters=args --timeout=compute-timeout

  constructor.automatic:
    super.set "+COPS" --parameters=[0, FORMAT-NUMERIC] --timeout=compute-timeout

  constructor.deregister:
    super.set "+COPS" --parameters=[2] --timeout=compute-timeout

  constructor.scan:
    super.test "+COPS" --timeout=compute-timeout

  constructor.read:
    super.read "+COPS" --timeout=compute-timeout

  // We use the deadline in the task to let the AT processor know that we can abort
  // the COPS operation by sending more AT commands.
  static compute-timeout -> Duration:
    if Task.current.deadline == null:
      return MAX-TIMEOUT
    else:
      return min MAX-TIMEOUT (Duration --us=(Task.current.deadline - Time.monotonic-us))
