// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io
import log
import monitor
import net
import net.tcp as tcp
import net.udp as udp
import uart

import system.base.network show CloseableNetwork

import .at as at
import .base
import .cellular
import .exceptions

/**
Driver scaffolding for cellular modules that speak the SIMCom-style multi-IP
  AT command set (CIPMUX / CIPSTART / CIPSEND / CIPRXGET / CIPSHUT / CDNSGIP).

Concrete drivers extend $CipCellular and provide the registration flow
  (connect_), any APN-write step (configure), and module-specific power
  control. The IP stack itself, the TCP/UDP socket classes, the DNS path,
  and the close/power-off flow are shared.
*/

CONNECTED-STATE_  ::= 1 << 0
READ-STATE_       ::= 1 << 1
CLOSE-STATE_      ::= 1 << 2

TIMEOUT-CIPSTART ::= Duration --s=75
TIMEOUT-CIPSEND  ::= Duration --s=10
TIMEOUT-CIPRXGET ::= Duration --s=5

monitor SocketState_:
  state_/int := 0
  dirty_/bool := false

  wait-for state --error-state=CLOSE-STATE_:
    bits := (state | error-state)
    await: state_ & bits != 0
    dirty_ = false
    return state_ & bits

  set-state state:
    dirty_ = true
    state_ |= state

  clear state:
    if not dirty_:
      state_ &= ~state

class Socket_:
  state_ ::= SocketState_
  cellular_/CipCellular
  id_/int? := ?

  constructor .cellular_ .id_:

  closed_:
    state_.set-state CLOSE-STATE_

  get-id_ -> int:
    if not id_: throw "socket is closed"
    return id_

  socket-call [block]:
    cellular_.at_.do: | session/at.Session |
      e := catch:
        return block.call session
      throw (UnknownException "SOCKET ERROR: $e")
    unreachable

class TcpSocket extends Socket_ with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  static MAX-SIZE_ ::= 1460

  peer-address/net.SocketAddress

  no-delay -> bool:
    return false

  no-delay= value/bool -> none:
    // Not supported.

  constructor cellular/CipCellular id/int .peer-address:
    super cellular id

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  /**
  Sends CIPSTART and waits for the async "<n>, CONNECT OK" response. Must be
    called after the socket is registered in the socket map so the
    on-unhandled-line callback can find it.
  */
  connect_:
    socket-call: | session/at.Session |
      session.set "+CIPSTART" --timeout=TIMEOUT-CIPSTART [
        get-id_,
        "TCP",
        peer-address.ip.stringify,
        "$peer-address.port",
      ]
    cellular_.wait-for-urc_: state_.wait-for CONNECTED-STATE_

  read -> ByteArray?:
    return in.read

  read_ -> ByteArray?:
    while true:
      state := cellular_.wait-for-urc_: state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        r := socket-call: | session/at.Session |
          session.set "+CIPRXGET" --timeout=TIMEOUT-CIPRXGET [2, get-id_, MAX-SIZE_]
        data-response := null
        r.responses.do: | resp |
          if resp[0] == 1:
            cellular_.sockets_.get resp[1]
                --if-present=: it.state_.set-state READ-STATE_
          else if resp[0] == 2:
            data-response = resp
        if not data-response:
          state_.clear READ-STATE_
          continue
        data-len := data-response[2]
        if data-len > 0: return data-response[4]
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  try-write_ data/io.Data from/int=0 to/int=data.byte-size -> int:
    if to == from: return 0
    if to - from > MAX-SIZE_: to = from + MAX-SIZE_
    data = data.byte-slice from to

    catch --unwind=(: it is not UnavailableException):
      socket-call: | session/at.Session |
        session.set "+CIPSEND" [get-id_, data.byte-size]
            --timeout=TIMEOUT-CIPSEND
            --data=data
      yield
      return data.byte-size

    sleep --ms=100
    return 0

  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    return out.try-write data from to

  close-write:
    out.close

  close-reader_:
    // Do nothing.

  close-writer_:
    // Do nothing.

  close:
    if id_:
      id := id_
      closed_
      id_ = null
      try:
        catch:
          cellular_.at_.do: | session/at.Session |
            if not session.is-closed:
              session.set "+CIPCLOSE" [id]
      finally:
        cellular_.sockets_.remove id

  mtu -> int:
    return 1500

class UdpSocket extends Socket_ implements udp.Socket:
  remote-address_/net.SocketAddress? := null
  connected_ := false

  constructor cellular/CipCellular id/int:
    super cellular id

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect address/net.SocketAddress:
    remote-address_ = address
    if not connected_:
      connected_ = true
      socket-call: | session/at.Session |
        session.set "+CIPSTART" --timeout=TIMEOUT-CIPSTART [
          get-id_,
          "UDP",
          address.ip.stringify,
          "$address.port",
        ]
      cellular_.wait-for-urc_: state_.wait-for CONNECTED-STATE_

  write data/io.Data from/int=0 to/int=data.byte-size -> int:
    if not remote-address_: throw "NOT_CONNECTED"
    if from != 0 or to != data.byte-size: data = data.byte-slice from to
    return send_ remote-address_ data

  read -> ByteArray?:
    msg := receive
    if not msg: return null
    return msg.data

  send datagram/udp.Datagram -> int:
    return send_ datagram.address datagram.data

  send_ address/net.SocketAddress data/io.Data -> int:
    if data.byte-size > mtu: throw "PAYLOAD_TO_LARGE"
    socket-call: | session/at.Session |
      session.set "+CIPSEND" [get-id_, data.byte-size]
          --timeout=TIMEOUT-CIPSEND
          --data=data
    return data.byte-size

  receive -> udp.Datagram?:
    while true:
      state := state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        r := socket-call: | session/at.Session |
          session.set "+CIPRXGET" --timeout=TIMEOUT-CIPRXGET [2, get-id_, 1460]
        data-response := null
        r.responses.do: | resp |
          if resp[0] == 1:
            cellular_.sockets_.get resp[1]
                --if-present=: it.state_.set-state READ-STATE_
          else if resp[0] == 2:
            data-response = resp
        if not data-response:
          state_.clear READ-STATE_
          continue
        data-len := data-response[2]
        if data-len > 0:
          return udp.Datagram
            data-response[4]
            remote-address_ or (net.SocketAddress (net.IpAddress.parse "0.0.0.0") 0)
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      id_ = null
      try:
        catch:
          cellular_.at_.do: | session/at.Session |
            if not session.is-closed:
              session.set "+CIPCLOSE" [id]
      finally:
        closed_
        cellular_.sockets_.remove id

  mtu -> int:
    return 1460

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Shared base for SIMCom-style multi-IP cellular modules.
*/
abstract class CipCellular extends CellularBase:
  resolve_/monitor.Latch? := null
  apn_/string := ""

  /**
  Set when AT+CPOWD=1 has been issued. Surfaced through $is-powered-off so
    the service framework can skip its hardware power-off fallback.
  */
  powered-off-cleanly_/bool := false

  /** Called when the driver should reset. */
  abstract on-reset session/at.Session

  constructor
      uart/uart.Port
      --logger/log.Logger
      --uart-baud-rates/List
      --use-psm/bool:
    at-session := configure-at_ uart logger

    super uart at-session
      --logger=logger
      --constants=CipConstants_
      --uart-baud-rates=uart-baud-rates
      --use-psm=use-psm

    at-session.register-urc "+CIPRXGET":: | args |
      if args[0] == 1:
        sockets_.get args[1]
            --if-present=: it.state_.set-state READ-STATE_

    at-session.register-urc "+CDNSGIP":: | args |
      if args[0] == 1 and args.size >= 3:
        if resolve_: resolve_.set args[2]
      else:
        if resolve_: resolve_.set --exception "DNS resolution failed: $args"

    // "<n>, CONNECT OK" etc. arrive without a "+" prefix, so handle them
    // via the unhandled-line callback.
    at-session.on-unhandled-line= :: | line/string |
      handle-unhandled-line_ line

  static configure-at_ uart/uart.Port logger/log.Logger -> at.Session:
    session := at.Session uart.in uart.out
      --logger=logger
      --data-marker='>'
      --command-delay=Duration --ms=20

    session.add-ok-termination "SEND OK"
    session.add-ok-termination "SHUT OK"
    session.add-ok-termination "CLOSE OK"
    session.add-error-termination "SEND FAIL"
    session.add-error-termination "+CME ERROR"
    session.add-error-termination "+CMS ERROR"

    session.add-response-parser "+CIPRXGET" :: | reader/io.Reader |
      line := reader.read-bytes-up-to '\r'
      parts := at.parse-response line
      if parts[0] == 1:
        parts
      else if parts[0] == 2:
        data-len := parts[2]
        if data-len > 0:
          reader.skip 1  // Skip '\n'.
          parts.add (reader.read-bytes data-len)
        parts
      else if parts[0] == 4:
        parts
      else:
        parts

    // ICCIDs are 19-20 digits; a 64-bit int can't hold the full value.
    session.add-response-parser "+CCID" :: | reader/io.Reader |
      iccid := reader.read-string-up-to session.s3
      [iccid.trim]

    return session

  support-gsm_ -> bool:
    return true

  /**
  Handles asynchronous non-URC lines like "<n>, CONNECT OK".
  Returns true if the line was recognized and handled.
  */
  handle-unhandled-line_ line/string -> bool:
    comma := line.index-of ", "
    if comma < 0: return false
    id := int.parse line[..comma] --if-error=: return false
    suffix := line[comma + 2..]
    if suffix == "CONNECT OK":
      sockets_.get id
          --if-present=: it.state_.set-state CONNECTED-STATE_
      return true
    else if suffix == "CONNECT FAIL" or suffix == "ALREADY CONNECT":
      sockets_.get id
          --if-present=: it.state_.set-state CLOSE-STATE_
      return true
    else if suffix == "CLOSED":
      sockets_.get id
          --if-present=: it.state_.set-state CLOSE-STATE_
      return true
    return false

  close:
    try:
      sockets_.values.do: it.closed_
      at_.do: | session/at.Session |
        if session.is-closed: return
        // CIPSHUT shuts the IP stack down. The spec allows up to ~65s; in
        // practice it returns in well under a second.
        catch: with-timeout --ms=10_000: session.action "+CIPSHUT"
        // CPOWD replies with "NORMAL POWER DOWN" rather than "OK" and then
        // stops driving its TX line, so a timeout waiting for OK is the
        // expected outcome — the modem is genuinely off afterwards.
        catch: with-timeout --ms=5_000: session.set "+CPOWD" [1]
        powered-off-cleanly_ = true
    finally:
      at-session_.close
      uart_.close

  is-powered-off -> bool?:
    return powered-off-cleanly_ ? true : null

  iccid -> string:
    r := at_.do: it.action "+CCID"
    return r.last[0]

  wait-for-ready_ session/at.Session:
    while true:
      power-on
      if select-baud_ session: break

  set-baud-rate_ session/at.Session baud-rate/int:
    // +IPR sets the fixed local UART rate; &W persists the profile.
    session.action "+IPR=$baud-rate;&W"
    uart_.baud-rate = baud-rate
    sleep --ms=100

  network-interface -> net.Interface:
    return CipInterface_ network-name this

  /**
  Returns the APN to feed to AT+CSTT. Returning "" causes $on-connected_ to
    skip CSTT (which works for SIMs that the network auto-provisions).

  The default returns the value $configure was last called with; LTE drivers
    typically override to fall back to CGDCONT for auto-APN SIMs.
  */
  effective-apn_ session/at.Session -> string:
    return apn_

  /**
  Brings up the SIMCom-style multi-IP TCP stack after registration.

  CIPSHUT first puts the stack into IP INITIAL — CIPMUX is only accepted
    there, and skipping CIPSHUT breaks reconnect-after-sleep where the
    previous IP stack is still up.
  */
  on-connected_ session/at.Session:
    session.action "+CIPSHUT"
    session.set "+CIPMUX" [1]
    session.set "+CIPRXGET" [1]
    apn := effective-apn_ session
    if apn != "":
      session.set "+CSTT" [apn]
    session.action "+CIICR" --timeout=(Duration --s=30)
    result := session.action "+CIFSR" --timeout=(Duration --s=5) --no-check
    logger.info "data connection up" --tags={"ip": result}

class CipConstants_ implements Constants:
  RatCatM1 -> int?: return null

class CipInterface_ extends CloseableNetwork implements net.Interface:
  name/string
  cellular_/CipCellular
  resolve-mutex_ ::= monitor.Mutex

  constructor .name .cellular_:

  resolve host/string -> List:
    catch:
      return [net.IpAddress.parse host]

    // DNS is async: AT+CDNSGIP returns OK immediately, then a +CDNSGIP URC
    // delivers the result.
    resolve-mutex_.do:
      cellular_.resolve_ = monitor.Latch
      try:
        cellular_.at_.do: | session/at.Session |
          session.set "+CDNSGIP" --timeout=(Duration --s=10) [host]
        cellular_.wait-for-urc_:
          result := cellular_.resolve_.get
          return [net.IpAddress.parse result]
      finally:
        cellular_.resolve_ = null
    unreachable

  udp-open -> udp.Socket:
    return udp-open --port=null

  udp-open --port/int? -> udp.Socket:
    id := socket-id_
    socket := UdpSocket cellular_ id
    cellular_.sockets_.update id --if-absent=(: socket): throw "socket already exists"
    return socket

  tcp-connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp-connect
        net.SocketAddress ips[0] port

  tcp-connect address/net.SocketAddress -> tcp.Socket:
    id := socket-id_
    socket := TcpSocket cellular_ id address
    cellular_.sockets_.update id --if-absent=(: socket): throw "socket already exists"
    socket.connect_
    return socket

  tcp-listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  socket-id_ -> int:
    // Multi-IP mode supports connection ids 0..5.
    6.repeat:
      if not cellular_.sockets_.contains it: return it
    throw
      ResourceExhaustedException "no more sockets available"

  address -> net.IpAddress:
    unreachable

  is-closed -> bool:
    return false

  close_:
    // Nothing to clean up.
