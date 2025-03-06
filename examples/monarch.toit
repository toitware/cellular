// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
This example demonstrates how to use the Monarch service and connect it to a
  cellular network.

To run this example using Jaguar, you'll first need to install the
  module service on the device.

$ jag pkg install --project-root examples/
$ jag container install monarch src/modules/sequans/monarch.toit
$ jag run examples/monarch.toit
*/

import http
import log
import net.cellular

main:
  config ::= {
    cellular.CONFIG-APN: "soracom.io",

    cellular.CONFIG-UART-TX: 5,
    cellular.CONFIG-UART-RX: 23,
    cellular.CONFIG-UART-RTS: 19,
    cellular.CONFIG-UART-CTS: 18,

    cellular.CONFIG-LOG-LEVEL: log.WARN-LEVEL,
  }

  logger := log.default.with-name "monarch"
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
