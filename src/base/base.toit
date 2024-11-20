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

REGISTRATION_DENIED_ERROR ::= "registration denied"

/**
Base functionality of Cellular modems, encapsulating the generic functionality.

Major things that are not implemented in the base is:
  * Chip configurations, e.g. bands and RATs.
  * TCP/UDP/IP stack.
*/
abstract class CellularBase implements Cellular:
  sockets_/Map ::= {:}
  logger/log.Logger
  at_session_/at.Session
  at_/at.Locker

  uart_/uart.Port
  uart_baud_rates/List

  cid_ := 1

  failed_to_connect/bool := false

  constants/Constants

  use_psm/bool := true

  is_lte_connection_ := false

  constructor
      .uart_
      .at_session_
      --.logger
      --.uart_baud_rates
      --.constants
      --.use_psm:
    at_ = at.Locker at_session_

  abstract iccid -> string

  abstract configure apn/string --bands/List?=null --rats=null

  abstract close -> none

  close_uart -> none:
    uart_.close

  support_gsm_ -> bool:
    return false

  model:
    r := at_.do: it.action "+CGMM"
    return r.last.first

  version:
    r := at_.do: it.action "+CGMR"
    return r.last.first

  scan_for_operators -> List:
    operators := []
    at_.do: | session/at.Session |
      result := send_abortable_ session COPS.scan
      operators = result.last

    result := []
    operators.do: | o |
      if o is List and o.size == 5 and o[1] is string and o[0] != 3:  // 3 = operator forbidden.
        rat := o[4] is int ? o[4] : null
        result.add
          Operator o[3] --rat=rat
    return result

  connect_psm -> none:
    at_.do: | session/at.Session |
      connect_ session --operator=null --psm

  connect --operator/Operator?=null -> none:
    at_.do: | session/at.Session |
      connect_ session --operator=operator --no-psm

  // TODO(Lau): Support the other operator formats than numeric.
  get_connected_operator -> Operator?:
    catch --trace:
      at_.do: | session/at.Session |
        res := (send_abortable_ session COPS.read).last
        if res.size == 4 and res[1] == COPS.FORMAT_NUMERIC and res[2] is string and res[2].size == 5:
          return Operator res[2]
    return null

  detach:
    at_.do: | session/at.Session |
      send_abortable_ session COPS.deregister

  signal_strength -> float?:
    quality := signal_quality
    return quality ? quality.power : null

  signal_quality -> SignalQuality?:
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

  wait_for_ready:
    at_.do: wait_for_ready_ it

  enable_radio:
    at_.do: | session/at.Session |
      session.send CFUN.online

  disable_radio -> none:
    at_.do: | session/at.Session |
      disable_radio_ session

  disable_radio_ session/at.Session:
    session.send CFUN.offline

  is_radio_enabled_ session/at.Session:
    result := session.send CFUN.get
    return result.single.first == "1"

  get_apn_ session/at.Session:
    ctx := session.read "+CGDCONT"
    ctx.responses.do:
      if it.first == cid_: return it[2]
    return ""

  set_apn_ session/at.Session apn:
    session.set "+CGDCONT" [cid_, "IP", apn]

  wait_for_ready_ session/at.Session:
    while true:
      // We try to power on the modem a number of
      // times (until we run out of time) to improve
      // the robustness of the power on sequence.
      power_on
      if select_baud_ session: break

  enter_configuration_mode_ session/at.Session:
    disable_radio_ session
    wait_for_sim_ session

  select_baud_ session/at.Session --count=5:
    preferred := uart_baud_rates.first
    count.repeat:
      uart_baud_rates.do: | rate |
        uart_.baud_rate = rate
        if is_ready_ session:
          // If the current rate isn't the preferred one, we assume
          // we can change it to the preferred one. If it already is
          // the preferred one, it is enough for us to know that we
          // can talk to the modem using the rate, so we conclude
          // that we correctly configured the rate.
          if rate != preferred:
            set_baud_rate_ session preferred
          return true
    return false

  is_ready_ session/at.Session:
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

  wait_for_sim_ session/at.Session:
    // Wait up to 10 seconds for the SIM to be initialized.
    40.repeat:
      catch --unwind=(: it == DEADLINE_EXCEEDED_ERROR):
        r := session.read "+CPIN"
        return
      sleep --ms=250

  wait_for_urc_ --session/at.Session?=null [block]:
    while true:
      catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout --ms=1000:
          return block.call
      // Ping every second
      if session: session.action "" --no-check
      else: at_.do: it.action "" --no-check

  connect_ session/at.Session --operator/Operator? --psm/bool -> none:
    failed_to_connect = true
    is_lte_connection_ = false

    done := monitor.Latch
    registrations := { "+CEREG" }
    if support_gsm_: registrations.add "+CGREG"
    failed := {}

    registrations.do: | command/string |
      session.register_urc command::
        state := it.first
        if state == 1 or state == 5:
          failed.remove command
          done.set command
        else if state == 3 or state == 80:
          failed.add command
          error := state == 3 ? REGISTRATION_DENIED_ERROR : "connection lost"
          // If all registrations have failed, we report the last error.
          if failed.size == registrations.size: done.set --exception error

    try:
      // Enable registration events.
      registrations.do: session.set it [2]

      if not psm:
        result := send_abortable_ session COPS.read
        cur_cops := result.single
        cur_mode := cur_cops[0]

        // If operator is defined, do manual operator selection.
        // Otherwise, only set new COPS value if it's not currently
        // set to automatic mode. Calling COPS=0 every time takes 
        // much longer.
        command := null
        if operator:
          command = COPS.manual operator.op --rat=operator.rat
        else if cur_mode != COPS.MODE_AUTOMATIC:
          command = COPS.automatic
        
        if command:
          send_abortable_ session command

      wait_for_urc_ --session=session:
        if done.get == "+CGREG":
          is_lte_connection_ = true
          use_psm = false

    finally:
      // TODO(kasper): Should we unregister the interest in the events?
      registrations.do: session.unregister_urc it

    on_connected_ session
    failed_to_connect = false

  send_abortable_ session/at.Session command/at.Command -> at.Result:
    try:
      return session.send command
    finally: | is_exception exception |
      if is_exception and exception.value == at.COMMAND_TIMEOUT_ERROR:
        on_aborted_command session command

  on_aborted_command session/at.Session command/at.Command -> none:
    // Do nothing by default.

  abstract set_baud_rate_ session/at.Session baud_rate/int

  abstract network_name -> string
  abstract network_interface -> net.Interface

  // Dummy implementations.
  power_on -> none:
  power_off -> none:
  reset -> none:
  is_powered_off -> bool?:
    return null

  /**
  Called when the driver has connected.
  */
  abstract on_connected_ session/at.Session

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

  constructor.reset --reset_sim/bool=false:
    super.set "+CFUN" --parameters=[reset_sim ? 16 : 15] --timeout=TIMEOUT

  constructor.get:
    super.read "+CFUN" --timeout=TIMEOUT

class COPS extends at.Command:
  // COPS times out after 180s, but since it can be aborted, any timeout can be used.
  static MAX_TIMEOUT ::= Duration --m=3
  static FORMAT_NUMERIC ::= 2
  static MODE_AUTOMATIC ::= 0
  static MODE_MANUAL ::= 1
  static MODE_DEREGISTER ::= 2
  static MODE_ONLY_FORMAT ::= 3
  static MODE_MANUAL_THEN_AUTO ::= 4
  static MODE_EXTENDED_SEARCH ::= 5
  static MODE_EXTENDED_SEARCH_NO_TAGS ::= 6
  constructor.manual operator --rat=null:
    args := [MODE_MANUAL, FORMAT_NUMERIC, operator]
    if rat: args.add rat
    super.set "+COPS" --parameters=args --timeout=compute_timeout

  constructor.automatic:
    super.set "+COPS" --parameters=[MODE_AUTOMATIC, FORMAT_NUMERIC] --timeout=compute_timeout

  constructor.deregister:
    super.set "+COPS" --parameters=[MODE_DEREGISTER] --timeout=compute_timeout

  constructor.scan:
    super.test "+COPS" --timeout=compute_timeout

  constructor.read:
    super.read "+COPS" --timeout=compute_timeout

  // We use the deadline in the task to let the AT processor know that we can abort
  // the COPS operation by sending more AT commands.
  static compute_timeout -> Duration:
    if Task.current.deadline == null:
      return MAX_TIMEOUT
    else:
      return min MAX_TIMEOUT (Duration --us=(Task.current.deadline - Time.monotonic_us))
