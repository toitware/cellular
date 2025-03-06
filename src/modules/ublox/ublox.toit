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
import ...base.xmodem-1k as xmodem-1k

SOCKET-LEVEL-TCP_ ::= 6

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
  cellular_/UBloxCellular
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  closed_:
    if id_: cellular_.sockets_.remove id_
    state_.set-state CLOSE-STATE_
    id_ = null

  get-id_:
    if not id_: throw "socket is closed"
    return id_

class TcpSocket extends Socket_ with io.CloseableInMixin io.CloseableOutMixin implements tcp.Socket:
  static OPTION-TCP-NO-DELAY_   ::= 1
  static OPTION-TCP-KEEP-ALIVE_ ::= 2
  static CTRL-TCP-OUTGOING_ ::= 11

  static MAX-BUFFERED_ ::= 10240
  // Sara R4 only supports up to 1024 bytes per write.
  static MAX-SIZE_ ::= 1024

  peer-address/net.SocketAddress ::= ?

  constructor cellular/UBloxCellular id/int .peer-address:
    super cellular id

  no-delay -> bool:
    // TODO(kasper): Implement this.
    return false

  no-delay= value/bool -> none:
    cellular_.at_.do: it.set "+USOSO" [get-id_, SOCKET-LEVEL-TCP_, OPTION-TCP-NO-DELAY_, value ? 1 : 0]

  local-address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    cmd ::= cellular_.async-socket-connect ? USOCO.async get-id_ peer-address : USOCO get-id_ peer-address
    cellular_.at_.do: it.send cmd
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
        r := cellular_.at_.do: it.set "+USORD" [get-id_, 1024]
        out := r.single
        if out[1] > 0: return out[2]
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

    // There is no safe way to detect how much data was sent, if an EAGAIN (buffer full)
    // was encountered. Instead query how much date is buffered, so we never hit it.
    buffered := (cellular_.at_.do: it.set "+USOCTL" [get-id_, CTRL-TCP-OUTGOING_]).single[2]
    if buffered + data.byte-size > MAX-BUFFERED_:
      // The buffer is full. Note that it can only drain at ~3.2 kbyte/s.
      sleep --ms=100
      // Update outgoing.
      return 0

    cellular_.at_.do: | session/at.Session |
      try:
        session.set "+USOWR" [get-id_, data.byte-size] --data=data
      finally: | is-exception _ |
        // If we get an exception while writing, we risk leaving the
        // modem in an awful state. Close the session to force us to
        // start over.
        if is-exception:
          session.close
          // The modem may become unresponsive at this point, so we
          // try to force it to power off.
          cellular_.power-off
    // Give processing time to other tasks, to avoid busy write-loop that starves readings.
    yield
    return data.byte-size

  close-reader_:
    // TODO(florian): is this the right way to close the reader?
    // Do nothing.

  /**
  Closes the socket for write. The socket will still be able to read incoming data.
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
      // Allow the close command to fail. If the socket has already been closed
      // but we haven't processed the notification yet, we sometimes get a
      // harmless 'operation not allowed' message that we ignore.
      catch --unwind=(: it != "+CME ERROR: Operation not allowed []"):
        cellular_.at_.do:
          if not it.is-closed:
            it.send
              cellular_.async-socket-close ? USOCL.async id : USOCL id

  mtu -> int:
    // Observed that packages are fragmented into 1390 chunks.
    return 1390

class UdpSocket extends Socket_ implements udp.Socket:
  remote-address_ := null

  constructor cellular/UBloxCellular id/int:
    super cellular id

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
    res := cellular_.at_.do: it.set "+USOST" [get-id_, address.ip.stringify, address.port, data.byte-size] --data=data
    return res.single[1]

  receive -> udp.Datagram?:
    while true:
      state := state_.wait-for READ-STATE_
      if state & CLOSE-STATE_ != 0:
        return null
      else if state & READ-STATE_ != 0:
        size := (cellular_.at_.do: it.set "+USORF" [get-id_, 0]).single[1]
        if size == 0:
          state_.clear READ-STATE_
          continue

        output := ByteArray size
        offset := 0
        ip := null
        port := null
        while offset < size:
          portion := (cellular_.at_.do: it.set "+USORF" [get-id_, 1024]).single
          output.replace offset portion[4]
          offset += portion[1]
          ip = net.IpAddress.parse portion[2]
          port = portion[3]
        return udp.Datagram
          output
          net.SocketAddress
            ip
            port
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      id := id_
      closed_
      cellular_.at_.do:
        if not it.is-closed:
          it.send
            USOCL id

  mtu -> int:
    // From spec, +USOST only allows sending 1024 bytes at a time.
    return 1024

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Base driver for u-blox Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class UBloxCellular extends CellularBase:
  static RAT-CAT-M1_        ::= 7
  static RAT-CAT-NB1_       ::= 8

  config_/Map

  cat-m1/bool
  cat-nb1/bool
  async-socket-connect/bool
  async-socket-close/bool

  /**
  Called when the driver should reset.
  */
  abstract on-reset session/at.Session

  constructor
      uart/uart.Port
      --logger/log.Logger
      --config/Map={:}
      --.cat-m1=false
      --.cat-nb1=false
      --uart-baud-rates/List
      --preferred-baud-rate=null
      --.async-socket-connect=false
      --.async-socket-close=false
      --use-psm:
    config_ = config
    at-session := configure-at_ uart logger

    super uart at-session
      --logger=logger
      --constants=UBloxConstants
      --uart-baud-rates=uart-baud-rates
      --use-psm=use-psm

    // TCP read event.
    at-session.register-urc "+UUSORD"::
      sockets_.get it[0]
        --if-present=: it.state_.set-state READ-STATE_

    // UDP read event.
    at-session.register-urc "+UUSORF"::
      sockets_.get it[0]
        --if-present=: it.state_.set-state READ-STATE_

    // Socket closed event
    at-session.register-urc "+UUSOCL"::
      sockets_.get it[0]
        --if-present=: it.closed_

    at-session.register-urc "+UUSOCO":: | args |
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

  static configure-at_ uart/uart.Port logger/log.Logger -> at.Session:
    at := at.Session uart.in uart.out
      --logger=logger
      --data-delay=Duration --ms=50
      --command-delay=Duration --ms=20

    at.add-error-termination "+CME ERROR"
    at.add-error-termination "+CMS ERROR"

    at.add-response-parser "+USORF" :: | reader/io.Reader |
      id := int.parse
          reader.read-string-up-to ','
      if (reader.peek-byte 0) == '"':
        // Data response.
        reader.skip 1
        ip := reader.read-string-up-to '"'
        reader.skip 1
        port := int.parse
            reader.read-string-up-to ','
        length := int.parse
            reader.read-string-up-to ','
        reader.skip 1  // Skip "
        data := reader.read-bytes length
        reader.read-bytes-up-to at.s3
        [id, length, ip, port, data]  // Return value.
      else:
        // Length-only response.
        length := int.parse
            reader.read-string-up-to at.s3
        [id, length]  // Return value.

    at.add-response-parser "+USORD" :: | reader/io.Reader |
      id := int.parse
          reader.read-string-up-to ','
      if (reader.peek-byte 0) == '"':
        // 0-length response.
        reader.read-bytes-up-to at.s3
        [id, 0]  // Return value.
      else:
        // Data response.
        length := int.parse
            reader.read-string-up-to ','
        reader.skip 1  // Skip "
        data := reader.read-bytes length
        reader.read-bytes-up-to at.s3
        [id, data.size, data]  // Return value.

    // Custom parsing as ICCID is returned as integer but larger than 64bit.
    at.add-response-parser "+CCID" :: | reader/io.Reader |
      iccid := reader.read-string-up-to at.s3
      [iccid]  // Return value.

    at.add-response-parser "+UFWUPD" :: | reader/io.Reader |
      state := reader.read-string-up-to at.s3
      [state]  // Return value.

    at.add-response-parser "+UFWSTATUS" :: | reader/io.Reader |
      status := reader.read-string-up-to at.s3
      (status.split ",").map --in-place: it.trim  // Return value.

    return at

  transfer-file [block]:
    // Enter file write mode.
    at_.do: it.send UFWUPD

    at_.do: it.pause: | uart |
      writer := xmodem-1k.Writer uart
      block.call writer
      writer.done

    // Wait for AT interface to become active again.
    wait-for-ready

  install-file:
    at_.do: it.action "+UFWINSTALL"
    wait-for-ready

  install-status:
    return (at_.do: it.read "+UFWSTATUS").single

  close:
    try:
      sockets_.values.do: it.closed_
      at_.do: | session/at.Session |
        if session.is-closed: return
        if use-psm and not failed-to-connect and not is-lte-connection_: return
        // If the chip was recently rebooted, wait for it to be responsive before
        // communicating with it again.
        attempts := 0
        while not select-baud_ session:
          if ++attempts > 5: return
        // Send the power-off command.
        session.send CPWROFF
    finally:
      at-session_.close
      uart_.close

  iccid:
    for attempts := 0; true; attempts++:
      at_.do: | session/at.Session |
        catch --unwind=(: attempts > 3):
          r := session.read "+CCID"
          return r.single[0]
      sleep --ms=1_000

  static MNO-UNDEFINED  /int ::= 0
  static MNO-SIM-SELECT /int ::= 1
  static MNO-GLOBAL     /int ::= 90
  should-set-mno_ session/at.Session mno/int -> bool:
    current-mno := get-mno_ session
    // If we're asking for SIM ICCID/IMSI select (1), we should only
    // set the MNO if it is currently undefined (0).
    if mno == MNO-SIM-SELECT: return current-mno == MNO-UNDEFINED
    // If we're asking for a standard MNO profile (starts at 100),
    // we're okay with getting back a global one. No need to set mno.
    if mno >= 100 and current-mno == MNO-GLOBAL: return false
    return current-mno != mno

  configure apn/string --mno/int=100 --bands=null --rats=null:
    at_.do: | session/at.Session |
      while true:
        should-reboot/bool := false
        enter-configuration-mode_ session

        if mno and should-set-mno_ session mno:
          set-mno_ session mno
          reboot_ session
          continue

        rat := []
        if cat-m1: rat.add RAT-CAT-M1_
        if cat-nb1: rat.add RAT-CAT-NB1_
        if (get-rat_ session) != rat:
          set-rat_ session rat
          should-reboot = true

        if bands:
          mask := 0
          bands.do: mask |= 1 << (it - 1)
          if not is-band-mask-set_ session mask:
            // We are already in offline mode (CFUN=0), so
            // we must not reboot in this case. We've seen
            // situations where the modem somehow resets the
            // band mask on reboot causing us to spin around
            // in a config loop.
            set-band-mask_ session mask

        if (get-apn_ session) != apn:
          // We are already in offline mode (CFUN=0), so
          // we must not reboot in this case. See comment
          // for the band mask setting.
          set-apn_ session apn

        if apply-configs_ session:
          should-reboot = true

        if configure-psm_ session --enable=use-psm:
          should-reboot = true

        if should-reboot:
          reboot_ session
          continue

        break

  // TODO(kasper): Testing - default periodic tau is 70h.
  configure-psm_ session/at.Session --enable/bool --periodic-tau/string="01000111" -> bool:
    cedrxs-changed/bool := false
    catch: cedrxs-changed = apply-config_ session "+CEDRXS" [0]

    psm-target := enable
        ? [1, null, null, periodic-tau, "00001000"]  // T3324=Requested_Active_Time is 16s.
        : [0]
    psv-target := enable
        ? psm-enabled-psv-target
        : [0]

    cpsms-changed/bool := apply-config_ session "+CPSMS" psm-target
    apply-config_ session "+UPSV" psv-target
    return reboot-after-cedrxs-or-cpsms-changes and (cedrxs-changed or cpsms-changed)

  abstract reboot-after-cedrxs-or-cpsms-changes -> bool
  abstract psm-enabled-psv-target -> List

  apply-configs_ session/at.Session -> bool:
    changed := false
    config_.do: | key expected |
      if apply-config_ session key expected: changed = true
    return changed

  apply-config_ session/at.Session key expected -> bool:
    values := session.read key
    line := values.last
    (min line.size expected.size).repeat:
      if line[it] != expected[it]:
        session.set key expected
        return true
    return false

  on-aborted-command session/at.Session command/at.Command -> none:
    // Clear out the aborted command.
    session.command-deadline_ = 0
    session.command_ = null
    // Flush out the CME ERROR: Command aborted response.
    exception := null
    iteration := 0
    attempts ::= []
    critical-do --no-respect-deadline:
      exception = catch --trace=(: it != DEADLINE-EXCEEDED-ERROR): with-timeout --ms=20_000:
        empty-ping := at.Command.raw "" --timeout=(Duration --ms=5_000)
        3.repeat:
          iteration++
          // Send empty ping to flush out "+CME ERROR: Command aborted" errors.
          handled := false
          start := Time.monotonic-us
          result := session.send_ empty-ping
              --on-timeout=:
                // Return an empty at.Result. We can't use null because send_ insists
                // on returning a non-null at.Result.
                attempts.add "-()"
                handled = true
                at.Result "" []
              --on-error=: | _ result/at.Result |
                // If we got an aborted command result, we're done!
                handled = true
                if result.code == "+CME ERROR: Command aborted":
                  elapsed := Time.monotonic-us - start
                  catch --trace: throw "SUCCESS: abort command after $iteration attempts in $(elapsed)us: $command - $attempts"
                  return
                attempts.add "-($result.code)"
          if not handled:
            attempts.add "+($result.code)"
    catch --trace: throw "FAILED: abort command after $iteration attempts: $command ($exception) - $attempts"

  get-mno_ session/at.Session:
    result := session.read "+UMNOPROF"
    return result.single[0]

  set-mno_ session/at.Session mno:
    session.set "+UMNOPROF" [mno]

  is-band-mask-set_ session/at.Session mask/int:
    result := session.read "+UBANDMASK"
    values := result.single
    // There may be multiple masks, validate all.
    for i := 1; i < values.size; i+=2:
      if values[i] != mask: return false
    return true

  set-band-mask_ session/at.Session mask:
    // Set mask for both m1 and nbiot.
    if cat-m1: session.set "+UBANDMASK" [0, mask]
    if cat-nb1: session.set "+UBANDMASK" [1, mask]

  get-rat_ session/at.Session -> List:
    result := session.read "+URAT"
    return result.single

  set-rat_ session/at.Session rat/List:
    session.set "+URAT" rat

  reset:
    detach
    // Reset of MNO will clear connction-related configurations.
    at_.do: | session/at.Session |
      set-mno_ session 0

  reboot_ session/at.Session:
    on-reset session
    // Rebooting the module should get it back into a ready state. We avoid
    // calling $wait_for_ready_ because it flips the power on, which is too
    // heavy an operation.
    5.repeat: if select-baud_ session: return
    wait-for-ready_ session

  set-baud-rate_  session/at.Session baud-rate:
    // Set the baud rate to the requested one.
    session.set "+IPR" [baud-rate]
    uart_.baud-rate = baud-rate
    sleep --ms=100

  network-interface -> net.Interface:
    return Interface_ network-name this

  test-tx_:
    // Test routine for entering test most and broadcasting 23dBm on channel 20
    // for 5 seconds at a time. Useful for EMC testing.
    at_.do: it.set "+UTEST" [1]
    reboot_ at-session_
    at_.do: it.set "+UTEST" [1]
    at_.do: it.read "+UTEST"
    at_.do: it.read "+CFUN"

    while true:
      at_.do: it.set "+UTEST" [3,124150,23,null,null,5000]

class UBloxConstants implements Constants:
  RatCatM1 -> int?: return null

class Interface_ extends CloseableNetwork implements net.Interface:
  name/string
  cellular_/UBloxCellular
  tcp-connect-mutex_ ::= monitor.Mutex

  constructor .name .cellular_:

  address -> net.IpAddress:
    unreachable

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    // Async resolve is not supported on this device.
    res := cellular_.at_.do: it.send
      UDNSRN.sync host
    return res.single.map: net.IpAddress.parse it

  udp-open --port/int?=null -> udp.Socket:
    if port and port != 0: throw "cannot bind to custom port"
    res := cellular_.at_.do: it.set "+USOCR" [17]
    id := res.single[0]
    socket := UdpSocket cellular_ id
    cellular_.sockets_.update id --if-absent=(: socket): throw "socket already exists"
    return socket

  tcp-connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp-connect
        net.SocketAddress ips[0] port

  tcp-connect address/net.SocketAddress -> tcp.Socket:
    res := cellular_.at_.do: it.set "+USOCR" [6]
    id := res.single[0]

    socket := TcpSocket cellular_ id address
    cellular_.sockets_.update id --if-absent=(: socket): throw "socket already exists"

    if not cellular_.async-socket-connect: socket.state_.set-state CONNECTED-STATE_

    // The chip only supports one connecting socket at a time.
    tcp-connect-mutex_.do:
      catch --unwind=(: socket.error_ = 1; true): socket.connect_

    return socket

  tcp-listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  is-closed -> bool:
    // TODO(kasper): Implement this?
    return false

  close_:
    // TODO(kasper): Implement this?

class UDNSRN extends at.Command:
  static TIMEOUT ::= Duration --s=70

  constructor.sync host/string:
    super.set "+UDNSRN" --parameters=[0, host] --timeout=TIMEOUT

class CPWROFF extends at.Command:
  static TIMEOUT ::= Duration --s=40

  constructor:
    super.action "+CPWROFF" --timeout=TIMEOUT

class USOCL extends at.Command:
  static TIMEOUT ::= Duration --s=120

  constructor id/int:
    super.set "+USOCL" --parameters=[id] --timeout=TIMEOUT

  constructor.async id/int:
    super.set "+USOCL" --parameters=[id, 1]

class UFWUPD extends at.Command:
  static TIMEOUT ::= Duration --s=20

  constructor:
    super.set "+UFWUPD" --parameters=[3] --timeout=TIMEOUT

class USOCO extends at.Command:
  static TIMEOUT ::= Duration --s=130

  constructor id/int address/net.SocketAddress:
    super.set "+USOCO" --parameters=[id, address.ip.stringify, address.port] --timeout=TIMEOUT

  constructor.async id/int address/net.SocketAddress:
    super.set "+USOCO" --parameters=[id, address.ip.stringify, address.port, 1]
