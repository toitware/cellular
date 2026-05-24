// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
This example demonstrates how to use the Air780E (or Air780EG) LTE Cat-1
  service and connect it to a cellular network.

To run this example using Jaguar, you'll first need to install the
  module service on the device:
$ jag pkg install --project-root examples/
$ jag container install air780e src/modules/luat/air780e.toit
$ jag run examples/air780e.toit

The driver assumes the module's 5V supply is gated by a relay that the
  configured power pin drives active-high. There is no PWRKEY or reset
  pin in this hardware setup.
*/

import http
import log
import net.cellular

main:
  config ::= {
    // Most modern SIMs (e.g., simbase) auto-pick the APN. If yours does
    // not, add `cellular.CONFIG-APN: "<your-apn>"` here.

    // Air780E + ESP32-C6 wiring on this board.
    cellular.CONFIG-UART-TX: 18,  // ESP TX -> modem RX.
    cellular.CONFIG-UART-RX: 20,  // ESP RX <- modem TX.

    cellular.CONFIG-POWER: [23, cellular.CONFIG-ACTIVE-HIGH],  // Relay on 5V.

    cellular.CONFIG-LOG-LEVEL: log.DEBUG-LEVEL,
  }

  logger := log.default.with-name "air780e"
  logger.info "opening network"
  network := cellular.open config

  try:
    client := http.Client network
    host := "www.google.com"
    response := client.get host "/"

    bytes := 0
    elapsed := Duration.of:
      while data := response.body.read:
        bytes += data.size

    logger.info "http get" --tags={"host": host, "size": bytes, "elapsed": elapsed}

  finally:
    network.close
