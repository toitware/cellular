// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import uart
import log

import net
import net.cellular

import encoding.tison
import system.assets
import system.containers

import system.services show ServiceHandler ServiceSelector ServiceProvider
import system.api.network show NetworkService
import system.api.cellular show CellularService
import system.base.network show ProxyingNetworkServiceProvider
import system.storage

import .cellular
import ..api.state

CELLULAR_FAILS_BETWEEN_RESETS /int ::= 8

CELLULAR_RESET_NONE      /int ::= 0
CELLULAR_RESET_SOFT      /int ::= 1
CELLULAR_RESET_POWER_OFF /int ::= 2

pin config/Map key/string -> gpio.Pin?:
  value := config.get key
  if not value: return null
  if value is int: return gpio.Pin value
  if value is not List or value.size != 2:
    throw "illegal pin configuration: $key == $value"

  pin := gpio.Pin value[0]
  mode := value[1]
  if mode != cellular.CONFIG_ACTIVE_HIGH: pin = gpio.InvertedPin pin
  pin.configure --output --open_drain=(mode == cellular.CONFIG_OPEN_DRAIN)
  pin.set 0  // Drive to in-active.
  return pin

abstract class CellularServiceProvider extends ProxyingNetworkServiceProvider:
  // We cellular service has been developed against known
  // versions of the network and cellular APIs. We keep a
  // copy of the versions here, so we will know if we the
  // version numbers in the core libraries change.
  static NETWORK_SELECTOR ::= ServiceSelector
      --uuid=NetworkService.SELECTOR.uuid
      --major=0
      --minor=3
  static CELLULAR_SELECTOR ::= ServiceSelector
      --uuid=CellularService.SELECTOR.uuid
      --major=0
      --minor=2

  // TODO(kasper): Let this be configurable.
  static SUSTAIN_FOR_DURATION_ ::= Duration --ms=100

  // TODO(kasper): Handle the configuration better.
  config_/Map? := null
  apn_/string? := null
  bands_/List? := null
  rats_/List? := null

  rx_/gpio.Pin? := null
  tx_/gpio.Pin? := null
  cts_/gpio.Pin? := null
  rts_/gpio.Pin? := null

  power_pin_/gpio.Pin? := null
  reset_pin_/gpio.Pin? := null

  driver_/Cellular? := null

  static ATTEMPTS_KEY ::= "attempts"
  bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitware.com/cellular"
  attempts_/int := ?
  reset_/int := CELLULAR_RESET_NONE

  constructor name/string --major/int --minor/int --patch/int=0:
    attempts/int? := null
    catch: attempts = bucket_.get ATTEMPTS_KEY
    attempts_ = attempts or 0
    super "system/network/cellular/$name" --major=major --minor=minor --patch=patch
    // The network starts closed, so we let the state of the cellular
    // container indicate that it is running in the background until
    // the network is opened.
    containers.notify-background-state-changed true
    provides NETWORK_SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY_UNPREFERRED
        --tags=["cellular"]
    provides CELLULAR_SELECTOR --handler=this
    provides CellularStateService.SELECTOR --handler=(CellularStateServiceHandler_ this)

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularService.CONNECT_INDEX:
      return connect client arguments
    return super index arguments --gid=gid --client=client

  abstract create_driver -> Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud_rates/List?

  connect client/int config/Map? -> List:
    if not config:
      config = {:}
      // TODO(kasper): It feels like the configurations present as assets
      // should form the basis (pins, etc.) and then additional options
      // provided by the client can give the rest as an overlay.
      assets.decode.get "cellular" --if_present=: | encoded |
        catch --trace: config = tison.decode encoded
      // TODO(kasper): Should we mix in configuration properties from
      // firmware.config?
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
    level := config_ ? config_.get cellular.CONFIG_LOG_LEVEL : null
    level = level or log.INFO_LEVEL
    logger := log.Logger level log.DefaultTarget --name="cellular"

    reset_ = CELLULAR_RESET_NONE
    attempts := ++attempts_
    bucket_[ATTEMPTS_KEY] = attempts
    attempts_since_reset ::= attempts % CELLULAR_FAILS_BETWEEN_RESETS
    attempts_until_reset ::= attempts_since_reset > 0
        ? (CELLULAR_FAILS_BETWEEN_RESETS - attempts_since_reset)
        : 0

    if attempts_until_reset == 0:
      power_off ::= attempts % (CELLULAR_FAILS_BETWEEN_RESETS * 2) == 0
      logger.info "forced reset" --tags={
        "attempts": attempts,
        "kind": power_off ? "power-off" : "soft"
      }
      reset_ = power_off ? CELLULAR_RESET_POWER_OFF : CELLULAR_RESET_SOFT
      if attempts >= 65536:
        attempts_ = attempts = 0
        bucket_[ATTEMPTS_KEY] = attempts

    driver ::= open_driver logger attempts_until_reset
    is_configured := false
    is_radio_enabled := false
    try:
      with_timeout --ms=30_000:
        apn := apn_ or ""
        logger.info "configuring apn" --tags={"apn": apn}
        driver.configure apn --bands=bands_ --rats=rats_
        is_configured = true
      with_timeout --ms=120_000:
        logger.info "enabling radio"
        driver.enable_radio
        is_radio_enabled = true
        logger.info "connecting"
        driver.connect
      driver_ = driver
      logger.info "connected"
      // Once the network is established, we change the state of the
      // cellular container to indicate that it is now running in
      // the foreground and needs to have its proxied networks closed
      // correctly in order for the shutdown to be clean.
      containers.notify-background-state-changed false
      return driver.network_interface
    finally: | is_exception exception |
      if is_exception:
        logger.warn "closing" --tags={"error": exception.value}
        if is_radio_enabled:
          // TODO(kasper): We should probably only detach after e.g. 10
          // failed attempts.
          catch: with_timeout --ms=10_000: driver.detach
          catch: with_timeout --ms=5_000: driver.disable_radio
        if is_configured:
          // The driver may try to communicate with the module as
          // part of closing down, so we need to be careful and
          // not wait forever for this.
          catch: with_timeout --ms=20_000: driver.close
        close_pins_

  close_network network/net.Interface -> none:
    logger := driver_.logger
    try:
      logger.info "closing"
      driver_.close
      if rts_:
        rts_.configure --output
        rts_.set 0
      wait_for_quiescent_ rx_

      // The call to driver_.close sends AT+CPWROFF. If the session wasn't
      // active, this can fail and therefore we probe its power state and
      // force it to power down if needed. The routine is not implemented
      // for all modems, in which case is_power_off will return null.
      // Therefore, we explicitly check for false.
      is_powered_off := driver_.is_powered_off
      if is_powered_off == false:
        logger.info "power off not complete, forcing power down"
        driver_.power_off
      else if is_powered_off == null:
        logger.info "cannot determine power state, assuming it's correctly powered down"
      else:
        logger.info "module is correctly powered off"

    finally:
      close_pins_
      apn_ = bands_ = rats_ = null
      driver_ = null
      critical_do:
        logger.info "closed"
        // After closing the network, we change the state of the cellular
        // container to indicate that it is now running in the background.
        containers.notify-background-state-changed true

  open_driver logger/log.Logger attempts_until_reset/int -> Cellular:
    uart_baud_rates/List? := config_.get cellular.CONFIG_UART_BAUD_RATE
        --if_present=: it is List ? it : [it]
    uart_high_priority/bool := config_.get cellular.CONFIG_UART_PRIORITY
        --if_present=: it == cellular.CONFIG_PRIORITY_HIGH
        --if_absent=: false

    tx_  = pin config_ cellular.CONFIG_UART_TX
    rx_  = pin config_ cellular.CONFIG_UART_RX
    cts_ = pin config_ cellular.CONFIG_UART_CTS
    rts_ = pin config_ cellular.CONFIG_UART_RTS

    power_pin_ = pin config_ cellular.CONFIG_POWER
    reset_pin_ = pin config_ cellular.CONFIG_RESET

    port := uart.Port
        --baud_rate=Cellular.DEFAULT_BAUD_RATE
        --high_priority=uart_high_priority
        --tx=tx_
        --rx=rx_
        --cts=cts_
        --rts=rts_

    driver := create_driver
        --logger=logger
        --port=port
        --rx=rx_
        --tx=tx_
        --rts=rts_
        --cts=cts_
        --power=power_pin_
        --reset=reset_pin_
        --baud_rates=uart_baud_rates

    try:
      if reset_ == CELLULAR_RESET_SOFT:
        driver.reset
        reset_ = CELLULAR_RESET_NONE
        sleep --ms=1_000
      else if reset_ == CELLULAR_RESET_POWER_OFF:
        driver.power_off
        reset_ = CELLULAR_RESET_NONE
        sleep --ms=1_000
      with_timeout --ms=20_000: driver.wait_for_ready
      return driver
    finally: | is_exception _ |
      if is_exception:
        driver.recover_modem
        close_pins_
        // Turning the cellular modem on failed, so we artificially
        // bump the number of attempts to get close to a reset.
        if attempts_until_reset > 1:
          attempts_ += attempts_until_reset - 1
          critical_do: bucket_[ATTEMPTS_KEY] = attempts_

  close_pins_ -> none:
    if tx_: tx_.close
    if rx_: rx_.close
    if cts_: cts_.close
    if rts_: rts_.close
    if power_pin_: power_pin_.close
    if reset_pin_: reset_pin_.close
    tx_ = rx_ = cts_ = rts_ = power_pin_ = reset_pin_ = null

    // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  static wait_for_quiescent_ pin/gpio.Pin:
    pin.configure --input
    while true:
      value := pin.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE_EXCEEDED_ERROR):
        with_timeout SUSTAIN_FOR_DURATION_:
          pin.wait_for 1 - value

      // If we timed out, we're done.
      if e: return

class CellularStateServiceHandler_ implements ServiceHandler CellularStateService:
  provider/CellularServiceProvider
  constructor .provider:

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularStateService.QUALITY_INDEX: return quality
    if index == CellularStateService.ICCID_INDEX: return iccid
    if index == CellularStateService.MODEL_INDEX: return model
    if index == CellularStateService.VERSION_INDEX: return version
    unreachable

  quality -> any:
    driver := provider.driver_
    if not driver: return null
    result := driver.signal_quality
    return result ? [ result.power, result.quality ] : null

  iccid -> string?:
    driver := provider.driver_
    if not driver: return null
    return driver.iccid

  model -> string?:
    driver := provider.driver_
    if not driver: return null
    return driver.model

  version -> string?:
    driver := provider.driver_
    if not driver: return null
    return driver.version
