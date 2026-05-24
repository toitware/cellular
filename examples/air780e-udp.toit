// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Sends an SNTP/v3 query to time.google.com:123 over UDP and prints the
  server's transmit timestamp converted to UTC.
*/

import io
import log
import net
import net.cellular
import net.udp

NTP-HOST ::= "time.google.com"
NTP-PORT ::= 123
NTP-EPOCH-OFFSET ::= 2_208_988_800  // Seconds between 1900-01-01 and 1970-01-01.

main:
  config ::= {
    // Most modern SIMs (e.g., simbase) auto-pick the APN. If yours does
    // not, add `cellular.CONFIG-APN: "<your-apn>"` here.
    cellular.CONFIG-UART-TX: 18,
    cellular.CONFIG-UART-RX: 20,
    cellular.CONFIG-POWER: [23, cellular.CONFIG-ACTIVE-HIGH],
    cellular.CONFIG-LOG-LEVEL: log.DEBUG-LEVEL,
  }

  logger := log.default.with-name "air780e-udp"
  logger.info "opening network"
  network := cellular.open config

  try:
    ips := network.resolve NTP-HOST
    address := net.SocketAddress ips[0] NTP-PORT
    logger.info "resolved" --tags={"host": NTP-HOST, "ip": ips[0]}

    socket := network.udp-open
    try:
      // Mode 3 (client), version 3, no leap indicator. All other bytes zero.
      request := ByteArray 48
      request[0] = 0x1B
      socket.connect address

      elapsed := Duration.of:
        socket.write request
        with-timeout --ms=10_000:
          response := socket.read
          if not response or response.size < 48:
            throw "short NTP response: $(response and response.size)"
          seconds := io.BIG-ENDIAN.uint32 response 40
          unix := seconds - NTP-EPOCH-OFFSET
          logger.info "ntp response"
              --tags={
                "size": response.size,
                "transmit_utc": (Time.epoch --s=unix).utc,
              }
      logger.info "udp round-trip" --tags={"elapsed": elapsed}

    finally:
      socket.close

  finally:
    network.close
