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
import ...base.location show Location GnssLocation

CONNECTED-STATE_  ::= 1 << 0
READ-STATE_       ::= 1 << 1
CLOSE-STATE_      ::= 1 << 2

TIMEOUT-QIOPEN ::= Duration --s=150
TIMEOUT-QIRD   ::= Duration --s=5
TIMEOUT-QISEND ::= Duration --s=5

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
    // Guard against clearing inread state (e.g. if state was updated
    // in between wait_for and clear).
    if not dirty_:
      state_ &= ~state

class Socket_:
  static ERROR-OK_                        ::= 0
  static ERROR-MEMORY-ALLOCATION-FAILED_  ::= 553
  static ERROR-OPERATION-BUSY_            ::= 568
  static ERROR-OPERATION-NOT-ALLOWED_     ::= 572

  state_ ::= SocketState_
  should-pdp-deact_ := false
  cellular_/QuectelCellular ::= ?
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  pdp-deact_:
    should-pdp-deact_ = true

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

  /**
  Returns the latest socket error (even if OK).
  */
  last-error_ cellular/at.Session original-error/string="" -> Exception:
    res := cellular.action "+QIGETERROR"
    print_ "Error $original-error -> $res.last"
    error := res.last[0]
    error-message := res.last[1]
    if error == ERROR-OK_:
      throw (UnavailableException original-error)
    if error == ERROR-OPERATION-BUSY_:
      throw (UnavailableException error-message)
    if error == ERROR-MEMORY-ALLOCATION-FAILED_:
      throw (UnavailableException error-message)
    if error == ERROR-OPERATION-NOT-ALLOWED_:
      throw (UnavailableException error-message)
    throw (UnknownException "SOCKET ERROR $error ($error-message - $original-error)")

class TcpSocket extends Socket_ with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  static MAX-SIZE_ ::= 1460

  peer-address/net.SocketAddress ::= ?

  no-delay -> bool:
    return false

  no-delay= value/bool -> none:
    // Not supported on BG96 (let's assume always disabled).

  constructor cellular id .peer-address:
    super cellular id

    socket-call:
      it.set "+QIOPEN" --timeout=TIMEOUT-QIOPEN [
        cellular_.cid_,
        get-id_,
        "TCP",
        peer-address.ip.stringify,
        peer-address.port
      ]

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
        r := socket-call: it.set "+QIRD" --timeout=TIMEOUT-QIRD [get-id_, 1500]
        out := r.single
        if out[0] > 0: return out[1]
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
        it.set "+QISEND" [get-id_, data.byte-size]
            --timeout=TIMEOUT-QISEND
            --data=data
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
  Deprecated. Call ($out).close instead.
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
      try:
        cellular_.at_.do:
          if should-pdp-deact_: it.send (QIDEACT id)
          if not it.is-closed:
            it.send
              QICLOSE id Duration.ZERO
      finally:
        cellular_.sockets_.remove id

  mtu -> int:
    return 1500

class UdpSocket extends Socket_ implements udp.Socket:
  remote-address_ := null

  constructor cellular/QuectelCellular id/int port/int:
    super cellular id

    socket-call:
      it.set "+QIOPEN" --timeout=TIMEOUT-QIOPEN [
        cellular_.cid_,
        get-id_,
        "UDP SERVICE",
        "127.0.0.1",
        0,
        port,
        0,
      ]

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect address/net.SocketAddress:
    remote-address_ = address

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
    res := socket-call:
      it.set "+QISEND" [get-id_, data.byte-size, address.ip.stringify, address.port]
          --timeout=TIMEOUT-QISEND
          --data=data
    return data.byte-size

  receive -> udp.Datagram?:
    while true:
      state := state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        res := socket-call: (it.set "+QIRD" --timeout=TIMEOUT-QIRD [get-id_]).single
        if res[0] > 0:
          return udp.Datagram
            res[3]
            net.SocketAddress
              net.IpAddress.parse res[1]
              res[2]

        state_.clear READ-STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      cellular_.at_.do:
        if not it.is-closed:
          it.send
            QICLOSE id_ Duration.ZERO
      closed_
      cellular_.sockets_.remove id_
      id_ = null

  mtu -> int:
    // From spec, +QISEND only allows sending 1460 bytes at a time.
    return 1460

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Base driver for Quectel Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class QuectelCellular extends CellularBase implements Gnss:
  resolve_/monitor.Latch? := null
  gnss-users_ := 0

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
      --constants=QuectelConstants
      --uart-baud-rates=uart-baud-rates
      --use-psm=use-psm

    at-session.register-urc "+QIOPEN":: | args |
      sockets_.get args[0]
        --if-present=: | socket |
          if args[1] == 0:
            // Success.
            if socket.error_ == 0:
              socket.state_.set-state CONNECTED-STATE_
            else:
              // The connection was aborted.
              socket.close
          else:
            socket.error_ = args[1]
            socket.closed_

    at-session.register-urc "+QIURC"::
      if it[0] == "dnsgip":
        if it[1] is int and it[1] != 0:
          if resolve_: resolve_.set --exception "RESOLVE FAILED: $it[1]"
        else if it[1] is string:
          if resolve_: resolve_.set it[1]
      else if it[0] == "recv":
        sockets_.get it[1]
          --if-present=: it.state_.set-state READ-STATE_
      else if it[0] == "closed":
        sockets_.get it[1]
          --if-present=: it.closed_
      else if it[0] == "pdpdeact":
        sockets_.get it[1]
          --if-present=:
            it.pdp-deact_
            it.closed_

  static configure-at_ uart/uart.Port logger/log.Logger -> at.Session:
    session := at.Session uart.in uart.out
      --logger=logger
      --data-marker='>'
      --command-delay=Duration --ms=20

    session.add-ok-termination "SEND OK"
    session.add-error-termination "SEND FAIL"
    session.add-error-termination "+CME ERROR"
    session.add-error-termination "+CMS ERROR"

    session.add-response-parser "+QIRD" :: | reader/io.Reader |
      line := reader.read-bytes-up-to '\r'
      parts := at.parse-response line
      if parts[0] == 0:
        [0]
      else:
        reader.skip 1  // Skip '\n'.
        parts.add (reader.read-bytes parts[0])
        parts

    // Custom parsing as ICCID is returned as integer but larger than 64bit.
    session.add-response-parser "+QCCID" :: | reader/io.Reader |
      iccid := reader.read-string-up-to session.s3
      [iccid]  // Return value.

    session.add-response-parser "+QIND" :: | reader/io.Reader |
      [reader.read-string-up-to session.s3]

    session.add-response-parser "+QIGETERROR" :: | reader/io.Reader |
      line := reader.read-bytes-up-to session.s3
      values := at.parse-response line --plain  // Return value.
      values[0] = int.parse values[0]
      values

    return session

  close:
    try:
      sockets_.values.do: it.closed_
      2.repeat: | attempt/int |
        catch: with-timeout --ms=1_500: at_.do: | session/at.Session |
          if not session.is-closed:
            if use-psm and not failed-to-connect and not is-lte-connection_:
              session.set "+QCFG" ["psm/enter", 1]
            else:
              session.send QPOWD
          return
        // If the chip was recently rebooted, wait for it to be responsive before
        // communicating with it again. Only do this once.
        if attempt == 0: wait-for-ready
    finally:
      at-session_.close
      uart_.close

  iccid:
    r := at_.do: it.action "+QCCID"
    return r.last[0]

  rats-to-scan-sequence_ rats/List? -> string:
    if not rats: return "00"

    res := ""
    rats.do: | rat |
      if rat == RAT-GSM:
        res += "01"
      else if rat == RAT-LTE-M:
        res += "02"
      else if rat == RAT-NB-IOT:
        res += "03"
    return res.is-empty ? "00" : res

  rats-to-scan-mode_ rats/List? -> int:
    if not rats: return 0  // Automatic.

    if rats.contains RAT-GSM:
      if rats.contains RAT-LTE-M or rats.contains RAT-NB-IOT:
        return 0
      else:
        return 1  // GSM only.

    if rats.contains RAT-LTE-M or rats.contains RAT-NB-IOT:
      return 3  // LTE only.

    return 0

  support-gsm_ -> bool:
    return true

  configure apn/string --bands=null --rats=null:
    at_.do: | session/at.Session |
      // Set connection arguments.

      while true:
        should-reboot := false
        enter-configuration-mode_ session

        // LTE only.
        session.set "+QCFG" ["nwscanmode", rats-to-scan-mode_ rats]
        // M1 only (M1 & NB1 is giving very slow connects).
        session.set "+QCFG" ["iotopmode", 0]
        // M1 -> NB1 (default).
        session.action "+QCFG=\"nwscanseq\",$(rats-to-scan-sequence_ rats)"
        // Only use GSM data service domain.
        session.action "+QCFG=\"servicedomain\",1"
        // Enable PSM URCs.
        session.set "+QCFG" ["psm/urc", 1]
        // Enable URC on uart1.
        session.set "+QURCCFG" ["urcport", "uart1"]
        session.set "+CTZU" [1]

        if bands:
          mask := 0
          bands.do: mask |= 1 << (it - 1)
          set-band-mask_ session mask

        if (get-apn_ session) != apn:
          set-apn_ session apn
          // TODO(kasper): It is unclear why we need to reboot here. The +CGDCONT
          // description in the Quectel manuals do not indicate that we should.
          should-reboot = true

        if should-reboot:
          reboot_ session
          continue

        configure-psm_ session --enable=use-psm
        set-up-psm-urc-handler_ session
        break

  configure-psm_ session/at.Session --enable/bool --periodic-tau/string="00111111":
    psm-target := enable ? 1 : 0
    value := session.read "+CPSMS"

    if value.last[0] == psm-target: return

    parameters := enable ? [psm-target, null, null, periodic-tau, "00000000"] : [psm-target]
    session.set "+CPSMS" parameters

  set-band-mask_ session/at.Session mask/int:
    // Set mask for both m1 and nbiot.
    hex-mask:= mask.stringify 16
    session.action "+QCFG=\"band\",0,$hex-mask,$hex-mask"

  set-up-psm-urc-handler_ session/at.Session:
    // The modem sometimes enters PSM unexpectedly. If a connection is
    // already established, then we need to restart to reestablish the
    // connection.
    lambda := :: throw "unexpected PSM enter"
    // We sometimes end up registering the +QPSMTIMER URC handler more
    // than once. Don't turn that into a problem.
    catch: session.register-urc "+QPSMTIMER" lambda

  connect-psm -> none:
    at_.do: | session/at.Session |
      set-up-psm-urc-handler_ session
    super

  network-interface -> net.Interface:
    return Interface_ network-name this

  // Override disable_radio_, as the SIM cannot be accessed unless airplane mode is used.
  disable-radio_ session/at.Session:
    session.send CFUN.airplane

  reset:
    detach
    // Factory reset.
    at_.do: it.action "&F"

  reboot_ session/at.Session:
    on-reset session
    // Rebooting the module should get it back into a ready state. We avoid
    // calling $wait_for_ready_ because it flips the power on, which is too
    // heavy an operation.
    5.repeat: if select-baud_ session: return
    wait-for-ready_ session

  set-baud-rate_ session/at.Session baud-rate:
    // Set baud rate and persist it.
    session.action "+IPR=$baud-rate;&W"
    uart_.baud-rate = baud-rate
    sleep --ms=100

  gnss-start:
    gnss-users_++
    at_.do: gnss-eval_ it

  gnss-location -> GnssLocation?:
    at_.do: | session/at.Session |
      gnss-eval_ session
      if gnss-users_ == 0: return null
      catch --unwind=(: it != at.COMMAND-TIMEOUT-ERROR and not it.contains "Not fixed now"):
        response := (session.set "+QGPSLOC" [2]).last
        latitude/float := response[1]
        longitude/float := response[2]
        horizontal-accuracy/float := response[3]
        altitude/float := response[4]
        return GnssLocation
            Location latitude longitude
            altitude
            Time.now
            horizontal-accuracy
            1.0  // vertical_accuracy
      return null
    unreachable

  gnss-stop:
    gnss-users_--
    at_.do: gnss-eval_ it

  gnss-eval_ session/at.Session -> none:
    state/int? ::= gnss-state_ session
    if not state: return
    if gnss-users_ > 0:
      if state != 1:
        session.set "+QGPS" [1]
    else if state != 0:
      session.action "+QGPSEND"

  gnss-state_ session/at.Session -> int?:
    3.repeat:
      catch:
        state := (session.read "+QGPS").last
        return state[0]
      // We sometimes see the QGPS read time out, so we try to
      // work around that by trying more than once. We make sure
      // we can read from the UART by caling $select_baud_.
      select-baud_ session
    return null

class QuectelConstants implements Constants:
  RatCatM1 -> int: return 8

class Interface_ extends CloseableNetwork implements net.Interface:
  static FREE-PORT-RANGE ::= 1 << 14

  name/string
  cellular_/QuectelCellular
  resolve-mutex_ ::= monitor.Mutex
  free-port_ := 0

  constructor .name .cellular_:

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    // The DNS resolution is async, so we have to serialize
    // the requests and take them one by one.
    resolve-mutex_.do:
      cellular_.resolve_ = monitor.Latch
      try:
        cellular_.at_.do:
          it.send (QIDNSGIP.async host)
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
    12.repeat:
      if not cellular_.sockets_.contains it: return it
    throw
      ResourceExhaustedException "no more sockets available"

  address -> net.IpAddress:
    unreachable

  is-closed -> bool:
    // TODO(kasper): Implement this?
    return false

  close_:
    // TODO(kasper): Implement this?

class QIDNSGIP extends at.Command:
  static TIMEOUT ::= Duration --s=70

  constructor.async host/string:
    super.set "+QIDNSGIP" --parameters=[1, host] --timeout=TIMEOUT

class QPOWD extends at.Command:
  static TIMEOUT ::= Duration --s=40

  constructor:
    super.set "+QPOWD" --parameters=[0] --timeout=TIMEOUT

class QICLOSE extends at.Command:
  constructor id/int timeout/Duration:
    super.set "+QICLOSE" --parameters=[id, timeout.in-s] --timeout=at.Command.DEFAULT-TIMEOUT + timeout

class QIACT extends at.Command:
  static TIMEOUT ::= Duration --s=150
  constructor id/int:
    super.set "+QIACT" --parameters=[id] --timeout=TIMEOUT

class QIDEACT extends at.Command:
  static TIMEOUT ::= Duration --s=40
  constructor id/int:
    super.set "+QIDEACT" --parameters=[id] --timeout=TIMEOUT

class QICFG extends at.Command:
  /**
    $idle-time in range 1-120, unit minutes.
    $interval-time in range 25-100, unit seconds.
    $probe-count in range 3-10.
  */
  constructor.keepalive --enable/bool --idle-time/int=1 --interval-time/int=30 --probe-count=3:
    ps := enable ? ["tcp/keepalive", 1, idle-time, interval-time, probe-count] : ["tcp/keepalive", 0]
    super.set "+QICFG" --parameters=ps
