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

CELLULAR-FAILS-BETWEEN-RESETS /int ::= 8

CELLULAR-RESET-NONE      /int ::= 0
CELLULAR-RESET-SOFT      /int ::= 1
CELLULAR-RESET-POWER-OFF /int ::= 2
CELLULAR-RESET-LABELS ::= ["none", "soft", "power-off"]

pin config/Map key/string -> gpio.Pin?:
  value := config.get key
  if not value: return null
  if value is int: return gpio.Pin value
  if value is not List or value.size != 2:
    throw "illegal pin configuration: $key == $value"

  pin := gpio.Pin value[0]
  mode := value[1]
  if mode != cellular.CONFIG-ACTIVE-HIGH: pin = gpio.InvertedPin pin
  pin.configure --output --open-drain=(mode == cellular.CONFIG-OPEN-DRAIN)
  pin.set 0  // Drive to in-active.
  return pin

abstract class CellularServiceProvider extends ProxyingNetworkServiceProvider:
  // We cellular service has been developed against known
  // versions of the network and cellular APIs. We keep a
  // copy of the versions here, so we will know if we the
  // version numbers in the core libraries change.
  static NETWORK-SELECTOR ::= ServiceSelector
      --uuid=NetworkService.SELECTOR.uuid
      --major=0
      --minor=4
  static CELLULAR-SELECTOR ::= ServiceSelector
      --uuid=CellularService.SELECTOR.uuid
      --major=0
      --minor=2

  // TODO(kasper): Let this be configurable.
  static SUSTAIN-FOR-DURATION_ ::= Duration --ms=100

  // TODO(kasper): Handle the configuration better.
  config_/Map? := null

  rx_/gpio.Pin? := null
  tx_/gpio.Pin? := null
  cts_/gpio.Pin? := null
  rts_/gpio.Pin? := null

  power-pin_/gpio.Pin? := null
  reset-pin_/gpio.Pin? := null

  driver_/Cellular? := null

  static ATTEMPTS-KEY ::= "attempts"
  bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitware.com/cellular"
  attempts_/int := ?

  constructor name/string --major/int --minor/int --patch/int=0:
    attempts/int? := null
    catch: attempts = bucket_.get ATTEMPTS-KEY
    attempts_ = attempts or 0
    super "system/network/cellular/$name" --major=major --minor=minor --patch=patch
    // The network starts closed, so we let the state of the cellular
    // container indicate that it is running in the background until
    // the network is opened.
    containers.notify-background-state-changed true
    provides NETWORK-SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY-UNPREFERRED
        --tags=["cellular"]
    provides CELLULAR-SELECTOR --handler=this
    provides CellularStateService.SELECTOR --handler=(CellularStateServiceHandler_ this)

  update-attempts_ value/int -> int:
    bucket_[ATTEMPTS-KEY] = value
    attempts_ = value
    return value

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularService.CONNECT-INDEX:
      return connect client arguments
    return super index arguments --gid=gid --client=client

  abstract create-driver -> Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud-rates/List?

  connect client/int config/Map? -> List:
    if not config:
      config = {:}
      // TODO(kasper): It feels like the configurations present as assets
      // should form the basis (pins, etc.) and then additional options
      // provided by the client can give the rest as an overlay.
      assets.decode.get "cellular" --if-present=: | encoded |
        catch --trace: config = tison.decode encoded
      // TODO(kasper): Should we mix in configuration properties from
      // firmware.config?
    // TODO(kasper): This isn't a super elegant way of dealing with
    // the current configuration. Should we pass it through to $open_network
    // somehow instead?
    config_ = config
    return connect client

  proxy-mask -> int:
    return NetworkService.PROXY-RESOLVE | NetworkService.PROXY-UDP | NetworkService.PROXY-TCP

  open-network -> net.Interface:
    level := config_.get cellular.CONFIG-LOG-LEVEL --if-absent=: log.INFO-LEVEL
    if level is string:
      // TODO(floitsch): use TRACE constant.
      if level == "TRACE": level = 0
      else if level == "DEBUG": level = log.DEBUG-LEVEL
      else if level == "INFO": level = log.INFO-LEVEL
      else if level == "WARN": level = log.WARN-LEVEL
      else if level == "ERROR": level = log.ERROR-LEVEL
    logger := log.Logger level log.DefaultTarget --name="cellular"

    driver/Cellular? := null
    catch: driver = open-driver logger
    // If we failed to create the driver, it may very well be
    // because we need to reset the modem. We give it one more
    // chance, so unless we're already past any deadline set up
    // by the caller of open, we'll get another shot at making
    // the modem communicate with us.
    if not driver: driver = open-driver logger

    apn := config_.get cellular.CONFIG-APN --if-absent=: ""
    bands := config_.get cellular.CONFIG-BANDS
    rats := config_.get cellular.CONFIG-RATS

    try:
      with-timeout --ms=30_000:
        logger.info "configuring modem" --tags={"apn": apn}
        driver.configure apn --bands=bands --rats=rats
      with-timeout --ms=120_000:
        logger.info "enabling radio"
        driver.enable-radio
        logger.info "connecting"
        driver.connect
      update-attempts_ 0  // Success. Reset the attempts.
      logger.info "connected"
      // Once the network is established, we change the state of the
      // cellular container to indicate that it is now running in
      // the foreground and needs to have its proxied networks closed
      // correctly in order for the shutdown to be clean.
      containers.notify-background-state-changed false
      return driver.network-interface
    finally: | is-exception exception |
      if is-exception:
        critical-do: close-driver driver --error=exception.value
      else:
        driver_ = driver

  close-network network/net.Interface -> none:
    driver := driver_
    driver_ = null
    logger := driver.logger
    critical-do:
      try:
        close-driver driver
      finally:
        // After closing the network, we change the state of the cellular
        // container to indicate that it is now running in the background.
        containers.notify-background-state-changed true

  open-driver logger/log.Logger -> Cellular:
    attempts := update-attempts_ attempts_ + 1
    attempts-since-reset ::= attempts % CELLULAR-FAILS-BETWEEN-RESETS
    attempts-until-reset ::= attempts-since-reset > 0
        ? (CELLULAR-FAILS-BETWEEN-RESETS - attempts-since-reset)
        : 0

    reset := CELLULAR-RESET-NONE
    if attempts-until-reset == 0:
      power-off ::= attempts % (CELLULAR-FAILS-BETWEEN-RESETS * 2) == 0
      reset = power-off ? CELLULAR-RESET-POWER-OFF : CELLULAR-RESET-SOFT
      if attempts >= 65536: attempts = update-attempts_ 0

    logger.info "initializing modem" --tags={
      "attempt": attempts,
      "reset": CELLULAR-RESET-LABELS[reset],
    }

    uart-baud-rates/List? := config_.get cellular.CONFIG-UART-BAUD-RATE
        --if-present=: it is List ? it : [it]
    uart-high-priority/bool := config_.get cellular.CONFIG-UART-PRIORITY
        --if-present=: it == cellular.CONFIG-PRIORITY-HIGH
        --if-absent=: false

    tx_  = pin config_ cellular.CONFIG-UART-TX
    rx_  = pin config_ cellular.CONFIG-UART-RX
    cts_ = pin config_ cellular.CONFIG-UART-CTS
    rts_ = pin config_ cellular.CONFIG-UART-RTS

    power-pin_ = pin config_ cellular.CONFIG-POWER
    reset-pin_ = pin config_ cellular.CONFIG-RESET

    port := uart.Port
        --baud-rate=Cellular.DEFAULT-BAUD-RATE
        --high-priority=uart-high-priority
        --tx=tx_
        --rx=rx_
        --cts=cts_
        --rts=rts_

    try:
      driver := create-driver
          --logger=logger
          --port=port
          --rx=rx_
          --tx=tx_
          --rts=rts_
          --cts=cts_
          --power=power-pin_
          --reset=reset-pin_
          --baud-rates=uart-baud-rates
      if reset == CELLULAR-RESET-SOFT:
        driver.reset
        sleep --ms=1_000
      else if reset == CELLULAR-RESET-POWER-OFF:
        driver.power-off
        sleep --ms=1_000
      with-timeout --ms=20_000: driver.wait-for-ready
      return driver
    finally: | is-exception _ |
      if is-exception:
        // Turning the cellular modem on failed, so we artificially
        // bump the number of attempts to get close to a reset.
        if attempts-until-reset > 1:
          critical-do: update-attempts_ attempts + attempts-until-reset - 1
        // Close the UART before closing the pins. This is typically
        // taken care of by a call to driver.close, but in this case
        // we failed to produce a working driver instance.
        port.close
        close-pins_

  close-driver driver/Cellular --error/any=null -> none:
    logger := driver.logger
    log-level := error ? log.WARN-LEVEL : log.INFO-LEVEL
    log-tags := error ? { "error": error } : null
    try:
      log.log log-level "closing" --tags=log-tags
      catch: with-timeout --ms=20_000: driver.close
      if rts_:
        rts_.configure --output
        rts_.set 0

      // It appears as if we have to wait for RX to settle down, before
      // we start to look at the power state.
      catch: with-timeout --ms=10_000: wait-for-quiescent_ rx_

      // The call to driver.close sends AT+CPWROFF. If the session wasn't
      // active, this can fail and therefore we probe its power state and
      // force it to power down if needed. The routine is not implemented
      // for all modems, in which case is_power_off will return null.
      // Therefore, we explicitly check for false.
      is-powered-off := driver.is-powered-off
      if is-powered-off == false:
        logger.info "power off not complete, forcing power down"
        driver.power-off
      else if is-powered-off == null:
        logger.info "cannot determine power state, assuming it's correctly powered down"
      else:
        logger.info "module is correctly powered off"

    finally:
      close-pins_
      log.log log-level "closed" --tags=log-tags

  close-pins_ -> none:
    if tx_: tx_.close
    if rx_: rx_.close
    if cts_: cts_.close
    if rts_: rts_.close
    if power-pin_: power-pin_.close
    if reset-pin_: reset-pin_.close
    tx_ = rx_ = cts_ = rts_ = power-pin_ = reset-pin_ = null

  // Block until a value has been sustained for at least $SUSTAIN_FOR_DURATION_.
  static wait-for-quiescent_ pin/gpio.Pin:
    pin.configure --input
    while true:
      value := pin.get

      // See if value is sustained for the required amount.
      e := catch --unwind=(: it != DEADLINE-EXCEEDED-ERROR):
        with-timeout SUSTAIN-FOR-DURATION_:
          pin.wait-for 1 - value

      // If we timed out, we're done.
      if e: return

      // Sleep for a little while. This allows us to take any
      // deadlines into consideration.
      sleep --ms=10

class CellularStateServiceHandler_ implements ServiceHandler CellularStateService:
  provider/CellularServiceProvider
  constructor .provider:

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularStateService.QUALITY-INDEX: return quality
    if index == CellularStateService.ICCID-INDEX: return iccid
    if index == CellularStateService.MODEL-INDEX: return model
    if index == CellularStateService.VERSION-INDEX: return version
    unreachable

  quality -> any:
    driver := provider.driver_
    if not driver: return null
    result := driver.signal-quality
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
