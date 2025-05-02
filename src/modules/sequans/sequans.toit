// Copyright (C) 2022 Toitware ApS. All rights reserved.
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

import ...base.at as at
import ...base.base
import ...base.cellular
import ...base.exceptions

CONNECTED-STATE_  ::= 1 << 0
READ-STATE_       ::= 1 << 1
CLOSE-STATE_      ::= 1 << 2

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
    // Guard against clearing unread state (e.g. if state was updated
    // in between wait_for and clear).
    if not dirty_:
      state_ &= ~state

class Socket_:
  state_ ::= SocketState_
  cellular_/SequansCellular ::= ?
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  closed_:
    state_.set-state CLOSE-STATE_

  get-id_:
    if not id_: throw "socket is closed"
    return id_

  /**
  Calls the given $block.
  Captures exceptions and translates them to socket-related errors.
  */
  socket-call [block]:
    // Ensure no other socket call can come in between.
    cellular_.at_.do: | session/at.Session |
      e := catch:
        return block.call session
      throw (last-error_ session e)
    unreachable

  last-error_ cellular/at.Session original-error/string="":
    throw (UnknownException "SOCKET ERROR $original-error")

class TcpSocket extends Socket_ with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  static MAX-SIZE_ ::= 1500
  static WRITE-TIMEOUT_ ::= Duration --s=5

  peer-address/net.SocketAddress ::= ?

  no-delay -> bool:
    // TODO(kasper): Implement this.
    return false

  no-delay= value/bool -> none:
    // TODO(kasper): Implement this.

  constructor cellular id .peer-address:
    super cellular id

    socket-call: | session/at.Session |
      // Configure socket to allow 8s timeout, and use 10s for the overall
      // AT command.
      session.set "+SQNSCFG" [
        get-id_,
        cellular_.cid_,
        0,   // Automatically choose packet size for online mode (default).
        0,   // Disable idle timeout.
        80,  // Connection timeout, 8s.
        50,  // Data write timeout for online mode, 5s (default).
      ]

      // Configure using default values. Without this, we sometimes see
      // the modem fetching the configuration from NVRAM, which leads
      // to errors when decoding SQNSRING messages if they contain
      // unexpected binary data.
      session.set "+SQNSCFGEXT" [
        get-id_,
        0,  // 0 = SQNSRING URC mode with no data (default).
        0,  // 0 = Data represented as text or raw binary (default).
        0,  // 0 = Keep-alive (0-240 seconds). Unused by modem.
      ]

      result := session.send
        SQNSD.tcp get-id_ peer-address
      if result.code == "OK": state_.set-state CONNECTED-STATE_

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    state := cellular_.wait-for-urc_: state_.wait-for CONNECTED-STATE_
    if state & CONNECTED-STATE_ != 0: return
    throw "CONNECT_FAILED: $error_"

  /**
  Deprecated. Use ($in).read instead.
  */
  read -> ByteArray?:
    return in.read

  read_ -> ByteArray?:
    while true:
      state := cellular_.wait-for-urc_: state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        socket-call: | session/at.Session |
          r := session.set "+SQNSI" [get-id_]
          if r.single[3] > 0:
            r = session.set "+SQNSRECV" [get-id_, 1500]
            out := r.single
            return out[1]
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  /**
  Deprecated. Use ($out).write or ($out).try-write instead.
  */
  write data from/int=0 to/int=data.size -> int:
    return out.try-write data from to

  try-write_ data/io.Data from/int=0 to/int=data.byte-size -> int:
    if to == from:
      return 0
    else if to - from > MAX-SIZE_:
      to = from + MAX-SIZE_
    data = data.byte-slice from to

    e := catch --unwind=(: it is not UnavailableException):
      socket-call:
        // Create a custom command, so we can experiment with the timeout.
        command ::= at.Command.set
            "+SQNSSENDEXT"
            --parameters=[get-id_, data.byte-size]
            --data=data
            --timeout=WRITE-TIMEOUT_
        start ::= Time.monotonic-us
        it.send command
        elapsed ::= Time.monotonic-us - start
        if elapsed > at.Command.DEFAULT-TIMEOUT.in-us:
          cellular_.logger.warn "slow tcp write" --tags={"time": "$(elapsed / 1_000) ms"}
      // Give processing time to other tasks, to avoid busy write-loop that starves readings.
      yield
      return data.byte-size

    // Buffer full, wait for buffer to be drained.
    sleep --ms=100
    return 0

  close-reader_:
    // Do nothing.

  /**
  Closes the socket for write. The socket is still be able to read incoming data.
  Deprecated. Use ($out).close instead.
  */
  close-write:
    out.close

  close-writer_:
    // Do nothing.

  // Immediately close the socket and release any resources associated.
  close:
    if id_:
      id := id_
      closed_
      id_ = null
      cellular_.at_.do:
        if not it.is-closed:
          it.set "+SQNSH" [id]
      cellular_.sockets_.remove id

  mtu -> int:
    return 1500

class UdpSocket extends Socket_ implements udp.Socket:
  remote-address_ := null
  port_/int

  constructor cellular/SequansCellular id/int .port_/int:
    super cellular id

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      port_

  connect address/net.SocketAddress:
    remote-address_ = address

    socket-call: | session/at.Session |
      session.send
        SQNSD.udp get-id_ port_ remote-address_

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

  send_ address data/io.Data -> int:
    if data.byte-size > mtu: throw "PAYLOAD_TO_LARGE"
    res := socket-call: it.set "+SQNSSENDEXT" [get-id_, data.byte-size] --data=data
    return data.byte-size

  receive -> udp.Datagram?:
    while true:
      state := state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        socket-call: | session/at.Session |
          r := session.set "+SQNSI" [get-id_]
          if r.single[3] > 0:
            r = session.set "+SQNSRECV" [get-id_, 1500]
            out := r.single
            return udp.Datagram
              out[1]
              remote-address_
        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      id_ = null
      closed_
      cellular_.at_.do:
        if not it.is-closed:
          it.set "+SQNSH" [id]
      cellular_.sockets_.remove id

  mtu -> int:
    return 1500

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Base driver for Sequans Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class SequansCellular extends CellularBase:
  closed_/monitor.Latch ::= monitor.Latch

  /**
  Called when the driver should reset.
  */
  abstract on-reset session/at.Session

  constructor
      uart/uart.Port
      --logger/log.Logger
      --uart-baud-rates/List
      --use-psm:
    at-session := configure-at_ uart logger

    super uart at-session
      --logger=logger
      --constants=SequansConstants
      --uart-baud-rates=uart-baud-rates
      --use-psm=use-psm

    at-session_.register-urc "+SQNSRING"::
      sockets_.get it[0]
        --if-present=: it.state_.set-state READ-STATE_

    at-session_.register-urc "+SQNSH"::
      sockets_.get it[0]
        --if-present=: it.state_.set-state CLOSE-STATE_

    at-session_.register-urc "+SQNSSHDN"::
      closed_.set null

  static configure-at_ uart/uart.Port logger/log.Logger -> at.Session:
    session := at.Session uart.in uart.out
      --logger=logger
      --data-marker='>'
      --command-delay=Duration --ms=20

    session.add-ok-termination "CONNECT"
    session.add-error-termination "+CME ERROR"
    session.add-error-termination "+CMS ERROR"
    session.add-error-termination "NO CARRIER"

    session.add-response-parser "+SQNSRECV" :: | reader/io.Reader |
      line := reader.read-bytes-up-to '\r'
      parts := at.parse-response line
      if parts[1] == 0:
        [0]
      else:
        reader.skip 1  // Skip '\n'.
        [parts[1], reader.read-bytes parts[1]]

    session.add-response-parser "+SQNBANDSEL" :: | reader/io.Reader |
      line := reader.read-bytes-up-to session.s3
      at.parse-response line --plain

    session.add-response-parser "+SQNDNSLKUP" :: | reader/io.Reader |
      line := reader.read-bytes-up-to session.s3
      at.parse-response line --plain

    return session

  close:
    try:
      sockets_.values.do: it.closed_
      at_.do: | session/at.Session |
        if session.is-closed: return
        // If the chip was recently rebooted, wait for it to be responsive before
        // communicating with it again.
        attempts := 0
        while not select-baud_ session:
          if ++attempts > 5: return
        // Send the shutdown command.
        session.send SQNSSHDN
    finally:
      at-session_.close
      uart_.close

  iccid:
    r := at_.do: it.read "+SQNCCID"
    return r.last[0]

  // Overriden since it doesn't appear to support deregister.
  detach:

  // Override disable_radio_, as the SIM cannot be accessed unless airplane mode is used.
  disable-radio_ session/at.Session:
    session.send CFUN.airplane

  // Override enable_radio as the Monarch modem needs a special sequence.
  enable-radio -> none:
    catch --trace=(: it != DEADLINE-EXCEEDED-ERROR) --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
      with-timeout (Duration --s=5):
        at_.do: | session/at.Session |
          try:
            waiter := monitor.Latch
            session.register-urc "+CEREG" ::
              if it.first == 2: waiter.set true
            // Force enable radio.
            session.send CFUN.online

            waiter.get
          finally:
            session.unregister-urc "+CEREG"

  ps-detach_ -> none:
    at_.do: | session/at.Session |
      try:
        waiter := monitor.Latch
        session.register-urc "+CEREG" ::
          if it.first == 0: waiter.set true
        session.set "+CGATT" [0]
        waiter.get
      finally:
        session.unregister-urc "+CEREG"

  connect --operator/Operator?=null -> none:
    if operator:
      ps-detach_
      // Using the RAT seems to give problems, so remove it.
      operator = Operator operator.op
    super --operator=operator

  scan-for-operators -> List:
    ps-detach_
    return super

  configure apn/string --bands=null --rats=null:
    at_.do: | session/at.Session |
      // Set connection arguments.

      while true:
        should-reboot := false
        enter-configuration-mode_ session

        // Set unsolicited events for CEREG to get radio ready.
        session.set "+CEREG" [2]

        session.set "+CPSMS" [0]
        session.set "+CEDRXS" [0]
        // Disable UART Break events in case of delayed URCs (default is to break after
        // 100ms).
        session.set "+SQNIBRCFG" [0]
        // Put the modem into deep-sleep mode after 100ms of low RTS.
        session.set "+SQNIPSCFG" [1, 100]

        if bands:
          bands-str := ""
          bands.size.repeat:
            if it > 0: bands-str += ","
            bands-str += bands[it].stringify
          set-band-mask_ session bands-str

        if (get-apn_ session) != apn:
          set-apn_ session apn
          should-reboot = true

        if should-reboot:
          reboot_ session
          continue

        break

  set-band-mask_ session/at.Session bands/string:
    // Set mask for m1.
    session.set "+SQNBANDSEL" [0, "standard", bands] --check=false
    // Set mask for nbiot.
    session.set "+SQNBANDSEL" [1, "standard", bands] --check=false

  reset:
    detach
    // Factory reset.
    at_.do: | session/at.Session |
      session.send RestoreFactoryDefaults
      session.action "^RESET"
      wait-for-ready_ session

  reboot_ session/at.Session:
    on-reset session
    // Rebooting the module should get it back into a ready state. We avoid
    // calling $wait_for_ready_ because it flips the power on, which is too
    // heavy an operation.
    5.repeat: if select-baud_ session: return
    wait-for-ready_ session

  set-baud-rate_ session/at.Session baud-rate/int:
    // NOP for Sequans devices.

  network-interface -> net.Interface:
    return Interface_ network-name this

class SequansConstants implements Constants:
  RatCatM1 -> int?: return null

class Interface_ extends CloseableNetwork implements net.Interface:
  static FREE-PORT-RANGE ::= 1 << 14

  name/string
  cellular_/SequansCellular
  free-port_ := 0

  constructor .name .cellular_:

  address -> net.IpAddress:
    unreachable

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    cellular_.at_.do:
      result := it.send
        SQNDNSLKUP host
      return result.single[1..].map: net.IpAddress.parse it
    unreachable

  udp-open --port/int?=null -> udp.Socket:
    id := socket-id_
    if not port or port == 0:
      // Best effort for rolling a free port.
      port = FREE-PORT-RANGE + free-port_++ % FREE-PORT-RANGE
    socket := UdpSocket cellular_ id port
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

    catch --unwind=(: socket.error_ = 1; true): socket.connect_

    return socket

  tcp-listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  socket-id_ -> int:
    6.repeat:
      if not cellular_.sockets_.contains it + 1: return it + 1
    throw
      ResourceExhaustedException "no more sockets available"

  is-closed -> bool:
    // TODO(kasper): Implement this?
    return false

  close_:
    // TODO(kasper): Implement this?

class SQNDNSLKUP extends at.Command:
  static TIMEOUT ::= Duration --s=20

  constructor host/string:
    super.set "+SQNDNSLKUP" --parameters=[host] --timeout=TIMEOUT

class SQNSSHDN extends at.Command:
  static TIMEOUT ::= Duration --s=10

  constructor:
    super.action "+SQNSSHDN" --timeout=TIMEOUT

class SQNSD extends at.Command:
  static TCP-TIMEOUT ::= Duration --s=20

  constructor.tcp id/int address/net.SocketAddress:
    super.set
      "+SQNSD"
      --parameters=[id, 0, address.port, address.ip.stringify, 0, 0, 1]
      --timeout=TCP-TIMEOUT

  constructor.udp id/int local-port/int address/net.SocketAddress:
    super.set
      "+SQNSD"
      --parameters=[id, 1, address.port, address.ip.stringify, 0, local-port, 1, 0]

class RestoreFactoryDefaults extends at.Command:
  static TIMEOUT ::= Duration --s=10

  constructor:
    super.action "&F" --timeout=TIMEOUT
