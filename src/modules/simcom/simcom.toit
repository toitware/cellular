// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import io
import net
import net.udp as udp
import net.tcp as tcp
import log
import monitor
import uart

import system.base.network show CloseableNetwork

import monitor

import ...base.at as at
import ...base.base
import ...base.cellular
import ...base.exceptions

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
  cellular_/SimcomCellular
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

  constructor cellular/SimcomCellular id/int .peer-address:
    super cellular id

    // CIPSTART returns OK first, then "<id>, CONNECT OK" when connected.
    // Both are recognized as OK terminations, so the command completes
    // on the first OK. The CONNECT OK arrives later and is ignored.
    socket-call: | session/at.Session |
      session.set "+CIPSTART" --timeout=TIMEOUT-CIPSTART [
        get-id_,
        "TCP",
        peer-address.ip.stringify,
        "$peer-address.port",
      ]
    // Wait for the CONNECT OK response.
    sleep --ms=3000

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    // On SIM800L, the connection is established after CIPSTART returns OK.
    // The "<id>, CONNECT OK" notification is not a standard URC and is
    // handled by the sleep in the constructor.

  read -> ByteArray?:
    return in.read

  read_ -> ByteArray?:
    while true:
      state := cellular_.wait-for-urc_: state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        // Response: +CIPRXGET: 2,<id>,<data_len>,<remaining_len>\r\n<data>
        // Parsed as: [2, id, data_len, remaining, data]
        r := socket-call: | session/at.Session |
          session.set "+CIPRXGET" --timeout=TIMEOUT-CIPRXGET [2, get-id_, MAX-SIZE_]
        out := r.single
        data-len := out[2]
        if data-len > 0: return out[4]
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  try-write_ data/io.Data from/int=0 to/int=data.byte-size -> int:
    if to == from: return 0
    if to - from > MAX-SIZE_: to = from + MAX-SIZE_
    data = data.byte-slice from to

    e := catch --unwind=(: it is not UnavailableException):
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

  constructor cellular/SimcomCellular id/int:
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
      // Wait for CONNECT OK.
      sleep --ms=3000

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
      // In multi-connection mode, UDP send is via CIPSEND with the
      // connection id.
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
        // Response: +CIPRXGET: 2,<id>,<data_len>,<remaining>\r\n<data>
        // Parsed as: [2, id, data_len, remaining, data]
        res := socket-call: | session/at.Session |
          (session.set "+CIPRXGET" --timeout=TIMEOUT-CIPRXGET [2, get-id_, 1460]).single
        data-len := res[2]
        if data-len > 0:
          return udp.Datagram
            res[4]
            remote-address_ or (net.SocketAddress (net.IpAddress.parse "0.0.0.0") 0)
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      id_ = null
      try:
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
Base driver for SIMCom cellular modules (GSM/GPRS).
*/
abstract class SimcomCellular extends CellularBase:
  apn_/string := ""
  resolve_/monitor.Latch? := null

  abstract on-reset session/at.Session

  constructor
      uart/uart.Port
      --logger/log.Logger
      --uart-baud-rates/List
      --use-psm/bool:
    at-session := configure-at_ uart logger

    super uart at-session
      --logger=logger
      --constants=SimcomConstants_
      --uart-baud-rates=uart-baud-rates
      --use-psm=use-psm

    // URC for data available (manual receive mode).
    at-session.register-urc "+CIPRXGET":: | args |
      if args[0] == 1:
        // Data available notification.
        sockets_.get args[1]
            --if-present=: it.state_.set-state READ-STATE_

    // URC for DNS resolution results.
    at-session.register-urc "+CDNSGIP":: | args |
      if args[0] == 1 and args.size >= 3:
        // Success: +CDNSGIP: 1,"hostname","ip1"[,"ip2"]
        if resolve_: resolve_.set args[2]
      else:
        if resolve_: resolve_.set --exception "DNS resolution failed: $args"

  static configure-at_ uart/uart.Port logger/log.Logger -> at.Session:
    session := at.Session uart.in uart.out
      --logger=logger
      --data-marker='>'
      --command-delay=Duration --ms=20

    session.add-ok-termination "SEND OK"
    session.add-ok-termination "SHUT OK"
    session.add-ok-termination "CLOSE OK"
    session.add-ok-termination "CONNECT OK"
    session.add-error-termination "SEND FAIL"
    session.add-error-termination "+CME ERROR"
    session.add-error-termination "+CMS ERROR"

    // CIPRXGET response parser.
    // Response format: +CIPRXGET: <mode>,<id>,<data_len>,<remaining_len>\r\n<data>
    session.add-response-parser "+CIPRXGET" :: | reader/io.Reader |
      line := reader.read-bytes-up-to '\r'
      parts := at.parse-response line
      if parts[0] == 1:
        // Data notification URC: +CIPRXGET: 1,<id>
        parts
      else if parts[0] == 2:
        // Data read response: +CIPRXGET: 2,<id>,<data_len>,<remaining_len>
        data-len := parts[2]
        if data-len > 0:
          reader.skip 1  // Skip '\n'.
          parts.add (reader.read-bytes data-len)
        parts
      else if parts[0] == 4:
        // Query unread data: +CIPRXGET: 4,<id>,<unread_len>
        parts
      else:
        parts

    // CCID response parser (ICCID is too large for int).
    session.add-response-parser "+CCID" :: | reader/io.Reader |
      iccid := reader.read-string-up-to session.s3
      [iccid.trim]

    // CIFSR doesn't have a "+CIFSR:" prefix - it just returns the IP address.
    // This is handled by the AT session as an unrecognized response line.

    return session

  support-gsm_ -> bool:
    return true

  close:
    try:
      sockets_.values.do: it.closed_
      catch: with-timeout --ms=3_000: at_.do: | session/at.Session |
        if not session.is-closed:
          session.action "+CIPSHUT"
          session.set "+CPOWD" [1]
    finally:
      at-session_.close
      uart_.close

  iccid:
    r := at_.do: it.action "+CCID"
    return r.last[0]

  /**
  Overrides the base connect to use only GSM registration commands.
  The SIM800L doesn't support LTE (+CEREG).
  */
  connect_ session/at.Session --operator/Operator?=null --psm/bool -> none:
    failed-to-connect = true

    done := monitor.Latch
    // SIM800L only supports GSM: +CREG and +CGREG.
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

  wait-for-ready_ session/at.Session:
    while true:
      power-on
      if select-baud_ session: break

  configure apn/string --bands/List?=null --rats/List?=null:
    apn_ = apn
    // On the SIM800L, the APN is set via AT+CSTT during on-connected_,
    // not via AT+CGDCONT. Just store it and wait for the SIM.
    at_.do: | session/at.Session |
      wait-for-sim_ session

  set-baud-rate_ session/at.Session baud-rate/int:
    session.action "+IPR=$baud-rate;&W"
    uart_.baud-rate = baud-rate
    sleep --ms=100

  network-interface -> net.Interface:
    return SimcomInterface_ network-name this

  /**
  Called after network registration succeeds.
  Sets up GPRS bearer and multi-connection mode.
  */
  abstract on-connected_ session/at.Session

class SimcomConstants_ implements Constants:
  RatCatM1 -> int?: return null

class SimcomInterface_ extends CloseableNetwork implements net.Interface:
  name/string
  cellular_/SimcomCellular
  resolve-mutex_ ::= monitor.Mutex

  constructor .name .cellular_:

  resolve host/string -> List:
    catch:
      return [net.IpAddress.parse host]

    // DNS resolution is async: AT+CDNSGIP returns OK immediately,
    // then sends a +CDNSGIP URC with the result.
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
    return socket

  tcp-listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  socket-id_ -> int:
    // SIM800L supports 6 connections (IDs 0-5) in multi-connection mode.
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
