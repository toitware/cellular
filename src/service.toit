// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import esp32
import gpio
import uart

import net
import net.cellular

import system.api.network show NetworkService
import system.api.cellular show CellularService
import system.base.network show ProxyingNetworkServiceDefinition

import .cellular

pin config/Map key/string -> gpio.Pin?:
  value := config.get key
  if not value: return null
  if value is int: return gpio.Pin value
  if value is not List or value.size != 2:
    throw "illegal pin configuration: $key == $value"

  pin := gpio.Pin value[0]
  mode := value[1]
  if mode != cellular.CONFIG_ACTIVE_HIGH: pin = gpio.InvertedPin pin
  pin.config --output --open_drain=(mode == cellular.CONFIG_OPEN_DRAIN)
  pin.set 0  // Drive to in-active.
  return pin

abstract class CellularServiceDefinition extends ProxyingNetworkServiceDefinition:
  // ... explain why these are here ...
  static MAJOR /int ::= 0
  static MINOR /int ::= 1

  // TODO(kasper): Let this be configurable.
  static SUSTAIN_FOR_DURATION_ ::= Duration --ms=100

  // TODO(kasper): Handle the configuration better.
  config_/Map? := null
  apn_/string? := null
  bands_/List? := null
  rats_/List? := null

  rx_/gpio.Pin? := null
  rts_/gpio.Pin? := null

  driver_/Cellular? := null

  constructor name/string --major/int --minor/int --patch/int=0:
    super "system/network/cellular/$name" --major=major --minor=minor --patch=patch
    // TODO(kasper): Provide the network service too and implement a default
    // way of establishing the connection.
    provides CellularService.UUID MAJOR MINOR

  handle pid/int client/int index/int arguments/any -> any:
    if index == CellularService.CONNECT_INDEX:
      return connect client (build_config arguments[0] arguments[1])
    return super pid client index arguments

  static build_config keys/List? values/List -> Map?:
    if not keys: return null
    config ::= {:}
    keys.size.repeat: config[keys[it]] = values[it]
    return config

  abstract create_driver --port/uart.Port --power/gpio.Pin? --reset/gpio.Pin? -> Cellular

  connect client/int config/Map? -> List:
    if not config:
      image ::= esp32.image_config or {:}
      config = image.get "cellular" --if_absent=: {:}
    // TODO(kasper): This isn't a super elegant way of dealing with
    // the current configuration. Should we pass it through to $open_network
    // somehow instead?
    config_ = config
    apn_ = config.get cellular.CONFIG_APN
    bands_ = config.get cellular.CONFIG_BANDS
    rats_ = config.get cellular.CONFIG_RATS
    return connect client

  proxy_mask -> int:
    return NetworkService.PROXY_RESOLVE | NetworkService.PROXY_UDP | NetworkService.PROXY_TCP

  open_network -> net.Interface:
    driver ::= open_driver
    try:
      with_timeout --ms=30_000:
        driver.configure apn_ --bands=bands_ --rats=rats_
      with_timeout --ms=120_000:
        driver.enable_radio
        driver.connect
      driver_ = driver
      return driver.network_interface
    finally: | is_exception _ |
      if is_exception:
        // TODO(kasper): It looks like this should be done after configure
        // has succeeded but not before.
        driver.close

  close_network network/net.Interface -> none:
    try:
      driver_.close
      if rts_:
        rts_.config --output
        rts_.set 0
      wait_for_quiescent_ rx_
    finally:
      apn_ = bands_ = rats_ = null
      rx_ = rts_ = null
      driver_ = null

  open_driver -> Cellular:
    baud_rate := config_.get cellular.CONFIG_UART_BAUD_RATE
        --if_absent=: Cellular.DEFAULT_BAUD_RATE

    tx := pin config_ cellular.CONFIG_UART_TX
    rx_ = pin config_ cellular.CONFIG_UART_RX
    cts := pin config_ cellular.CONFIG_UART_CTS
    rts_ = pin config_ cellular.CONFIG_UART_RTS

    power := pin config_ cellular.CONFIG_POWER
    reset := pin config_ cellular.CONFIG_RESET

    port := uart.Port
        --baud_rate=baud_rate
        --tx=tx
        --rx=rx_
        --cts=cts
        --rts=rts_

    driver := create_driver
        --port=port
        --power=power
        --reset=reset

    try:
      driver.wait_for_ready
      return driver
    finally: | is_exception _ |
      if is_exception:
        driver.recover_modem
        // TODO(kasper): There probably isn't a need to do this before
        // configure has succeeded.
        driver.close

    // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  static wait_for_quiescent_ pin/gpio.Pin:
    pin.config --input
    while true:
      value := pin.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout SUSTAIN_FOR_DURATION_:
          pin.wait_for 1 - value

      // If we timed out, we're done.
      if e: return
