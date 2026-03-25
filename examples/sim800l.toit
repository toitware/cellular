// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
This example demonstrates how to use the SIM800L service and connect it to a
  cellular network.

To run this example using Jaguar, you'll first need to install the
  module service on the device.

For a LilyGO T-Call board, use the T-Call specific wrapper to handle
  the board's power management IC:
$ jag pkg install --project-root examples/
$ jag container install sim800l examples/sim800l-tcall.toit
$ jag run examples/sim800l.toit

For other boards, install the base driver:
$ jag container install sim800l src/modules/simcom/sim800l.toit
*/

import http
import log
import net.cellular

main:
  config ::= {
    // Set to your SIM card's APN.
    cellular.CONFIG-APN: "simbase",

    // LilyGO T-Call SIM800L pinout.
    cellular.CONFIG-UART-TX: 27,
    cellular.CONFIG-UART-RX: 26,

    cellular.CONFIG-POWER: [4, cellular.CONFIG-ACTIVE-HIGH],  // PWRKEY.
    cellular.CONFIG-RESET: [5, cellular.CONFIG-ACTIVE-LOW],  // RST (active-low).

    cellular.CONFIG-LOG-LEVEL: log.DEBUG-LEVEL,
  }

  logger := log.default.with-name "sim800l"
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
