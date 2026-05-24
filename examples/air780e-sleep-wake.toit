// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Demonstrates a software-driven sleep / wake cycle on the Air780E.

  1. Brings the modem up (relay-on for the cold start; subsequent transitions
     don't touch the relay).
  2. Registers, brings up the data connection, fetches a small URL.
  3. Calls disable-radio (AT+CFUN=4 → airplane mode). Radio off, low power,
     but UART responsive — no CPOWD, no relay toggle.
  4. Sleeps a few seconds.
  5. Calls enable-radio (AT+CFUN=1) and reconnects.
  6. Fetches another URL.
  7. Cleanly closes (AT+CPOWD=1).
*/

import gpio
import http
import log
import net
import uart

import cellular.modules.luat.air780e show Air780e

PWR-PIN ::= 23
TX-PIN  ::= 18
RX-PIN  ::= 20

main:
  logger := log.Logger log.DEBUG-LEVEL log.DefaultTarget --name="air780e"

  power := gpio.Pin PWR-PIN --output
  port := uart.Port --tx=(gpio.Pin TX-PIN) --rx=(gpio.Pin RX-PIN) --baud-rate=115200

  driver := Air780e port logger --power-pin=power --baud-rates=[115_200]

  try:
    logger.info "cold boot via relay"
    driver.wait-for-ready
    driver.configure ""        // No explicit APN — use SIM's default.
    driver.enable-radio
    driver.connect
    iface := driver.network-interface
    fetch logger iface --label="first request"

    // Soft shutdown. AT+CFUN=4 turns the radio off but keeps the modem
    // alive on UART — no CPOWD, no relay toggle.
    logger.info "soft-shutdown (CFUN=4)"
    driver.disable-radio

    logger.info "sleeping 5s with radio off"
    sleep --ms=5_000

    // Wake. AT+CFUN=1 re-enables the radio.
    logger.info "wake (CFUN=1) and re-register"
    driver.enable-radio
    driver.connect
    fetch logger iface --label="second request"

  finally:
    logger.info "graceful CPOWD"
    driver.close

fetch logger/log.Logger network/net.Interface --label/string:
  client := http.Client network
  try:
    response := client.get "example.com" "/"
    bytes := 0
    elapsed := Duration.of:
      while data := response.body.read:
        bytes += data.size
    logger.info label --tags={"size": bytes, "elapsed": elapsed}
  finally:
    client.close
