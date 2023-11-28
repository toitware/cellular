// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import uart
import log
import monitor

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
import ..api.location
import ..config

CELLULAR_FAILS_BETWEEN_RESETS /int ::= 8

CELLULAR_RESET_NONE      /int ::= 0
CELLULAR_RESET_SOFT      /int ::= 1
CELLULAR_RESET_POWER_OFF /int ::= 2
CELLULAR_RESET_LABELS ::= ["none", "soft", "power-off"]

abstract class CellularServiceProvider extends ProxyingNetworkServiceProvider:
  // We cellular service has been developed against known
  // versions of the network and cellular APIs. We keep a
  // copy of the versions here, so we will know if we the
  // version numbers in the core libraries change.
  static NETWORK_SELECTOR ::= ServiceSelector
      --uuid=NetworkService.SELECTOR.uuid
      --major=0
      --minor=4
  static CELLULAR_SELECTOR ::= ServiceSelector
      --uuid=CellularService.SELECTOR.uuid
      --major=0
      --minor=2

  // TODO(kasper): Let this be configurable.
  static SUSTAIN_FOR_DURATION_ ::= Duration --ms=100

  config/CellularConfiguration

  driver_/Cellular? := null
  driver_clients_/int := 0
  driver_mutex_/monitor.Mutex := monitor.Mutex

  static ATTEMPTS_KEY ::= "attempts"
  bucket_/storage.Bucket ::= storage.Bucket.open --flash "toitware.com/cellular"
  attempts_/int := ?

  constructor name/string --major/int --minor/int --patch/int=0 --.config:
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

  update_attempts_ value/int -> int:
    bucket_[ATTEMPTS_KEY] = value
    attempts_ = value
    return value

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == CellularService.CONNECT_INDEX:
      return connect client arguments
    return super index arguments --gid=gid --client=client

  abstract create_driver -> Cellular
      --logger/log.Logger
      --port/uart.Port
      --config/CellularConfiguration

  open_driver --logger:
    driver_mutex_.do:
      if driver_:
        driver_clients_++
        driver_.logger.debug "increasing driver count to $driver_clients_"
        return

      // Before the driver is initialized, we change the state of the
      // cellular container to indicate that it is now running in
      // the foreground and needs to have its driver release
      // in order for the shutdown to be clean.
      containers.notify-background-state-changed false
      is-created := false
      try:
        driver/Cellular? := null
        catch: driver = open_driver_ logger
        // If we failed to create the driver, it may very well be
        // because we need to reset the modem. We give it one more
        // chance, so unless we're already past any deadline set up
        // by the caller of open, we'll get another shot at making
        // the modem communicate with us.
        if not driver: driver = open_driver_ logger
        driver_clients_ = 1
        driver_ = driver
        is-created = true
      finally:
        if not is-created:
          // We failed to create the driver, so mark the container free
          // to be stopped
          containers.notify-background-state-changed true

  close_driver --error/any=null:
    driver_clients_--
    if driver_clients_ == 0:
      driver := driver_
      driver_ = null
      driver_mutex_.do:
        critical_do:
          try:
            close_driver_ driver --error=error
          finally:
            // After closing the driver, we change the state of the cellular
            // container to indicate that it is now running in the background.
            containers.notify-background-state-changed true
    else:
      log_level := error ? log.WARN_LEVEL : log.INFO_LEVEL
      log_tags := error ? { "error": error } : null
      driver_.logger.log log_level "decreasing driver count to to $driver_clients_" --tags=log_tags

  connect client/int config/Map? -> List:
    this.config.update-from-map_ config
    return connect client

  proxy_mask -> int:
    return NetworkService.PROXY_RESOLVE | NetworkService.PROXY_UDP | NetworkService.PROXY_TCP

  open_network -> net.Interface:
    logger := log.Logger config.log-level log.DefaultTarget --name="cellular"

    open_driver --logger=logger

    try:
      with_timeout --ms=30_000:
        logger.info "configuring modem" --tags={"apn": config.apn}
        driver_.configure config.apn --bands=config.bands --rats=config.rats
      with_timeout --ms=120_000:
        logger.info "enabling radio"
        driver_.enable_radio
        logger.info "connecting"
        driver_.connect
      update-attempts_ 0  // Success. Reset the attempts.
      logger.info "connected"

      return driver_.network_interface
    finally: | is_exception exception |
      if is_exception:
        close_driver

  close_network network/net.Interface -> none:
    close_driver

  open_driver_ logger/log.Logger -> Cellular:
    attempts := update_attempts_ attempts_ + 1
    attempts_since_reset ::= attempts % CELLULAR_FAILS_BETWEEN_RESETS
    attempts_until_reset ::= attempts_since_reset > 0
        ? (CELLULAR_FAILS_BETWEEN_RESETS - attempts_since_reset)
        : 0

    reset := CELLULAR_RESET_NONE
    if attempts_until_reset == 0:
      power_off ::= attempts % (CELLULAR_FAILS_BETWEEN_RESETS * 2) == 0
      reset = power_off ? CELLULAR_RESET_POWER_OFF : CELLULAR_RESET_SOFT
      if attempts >= 65536: attempts = update_attempts_ 0

    logger.info "initializing modem" --tags={
      "attempt": attempts,
      "reset": CELLULAR_RESET_LABELS[reset],
    }

    port := uart.Port
        --baud_rate=Cellular.DEFAULT_BAUD_RATE
        --high_priority=config.uart-high-priority
        --tx=config.uart-tx
        --rx=config.uart-rx
        --cts=config.uart-cts
        --rts=config.uart-rts

    driver := create_driver
        --logger=logger
        --port=port
        --config=config

    try:
      if reset == CELLULAR_RESET_SOFT:
        driver.reset
        sleep --ms=1_000
      else if reset == CELLULAR_RESET_POWER_OFF:
        driver.power_off
        sleep --ms=1_000
      with_timeout --ms=20_000: driver.wait_for_ready
      return driver
    finally: | is_exception _ |
      if is_exception:
        // Turning the cellular modem on failed, so we artificially
        // bump the number of attempts to get close to a reset.
        if attempts_until_reset > 1:
          critical_do: update_attempts_ attempts + attempts_until_reset - 1
        // Close the UART before closing the pins. This is typically
        // taken care of by a call to driver.close, but in this case
        // we failed to produce a working driver instance.
        port.close
        close_pins_

  close_driver_ driver/Cellular --error/any=null -> none:
    logger := driver.logger
    log_level := error ? log.WARN_LEVEL : log.INFO_LEVEL
    log_tags := error ? { "error": error } : null
    try:
      log.log log_level "closing" --tags=log_tags
      catch: with_timeout --ms=20_000: driver.close
      if config.uart-rts:
        config.uart-rts.configure --output
        config.uart-rts.set 0

      // It appears as if we have to wait for RX to settle down, before
      // we start to look at the power state.
      catch: with_timeout --ms=10_000: wait_for_quiescent_ config.uart-rx

      // The call to driver.close sends AT+CPWROFF. If the session wasn't
      // active, this can fail and therefore we probe its power state and
      // force it to power down if needed. The routine is not implemented
      // for all modems, in which case is_power_off will return null.
      // Therefore, we explicitly check for false.
      is_powered_off := driver.is_powered_off
      if is_powered_off == false:
        logger.info "power off not complete, forcing power down"
        driver.power_off
      else if is_powered_off == null:
        logger.info "cannot determine power state, assuming it's correctly powered down"
      else:
        logger.info "module is correctly powered off"

    finally:
      close_pins_
      log.log log_level "closed" --tags=log_tags

  close_pins_ -> none:
    config.close-owned-pins_

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

      // Sleep for a little while. This allows us to take any
      // deadlines into consideration.
      sleep --ms=10


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


abstract class LocationServiceProvider extends CellularServiceProvider:
  gnss-started/bool := false

  constructor name/string --major/int --minor/int --patch/int=0 --config/CellularConfiguration:
    super "location/$name" --major=major --minor=minor --patch=patch --config=config
    provides LocationService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == LocationService.START-INDEX:
      return start-location arguments
    else if index == LocationService.READ-LOCATION-INDEX:
      return read-location
    else if index == LocationService.STOP-INDEX:
      return stop-location

    return super index arguments --gid=gid --client=client

  start-location config-map/Map?:
    if gnss-started:
      throw "INVALID_STATE"
    config.update-from-map_ config-map

    logger := log.Logger config.log-level log.DefaultTarget --name="cellular"

    open_driver --logger=logger

    gnss := driver_ as Gnss

    try:
      logger.info "connecting to location service on modem"
      gnss.gnss_start
    finally: | is_exception e |
      if is_exception:
        close_driver
      else:
        gnss-started = true

  read-location:
    if not gnss-started:
      throw "INVALID_STATE"
    location := (driver_ as Gnss).gnss_location
    if not location: return null
    return location.to_byte_array

  stop-location:
    if not gnss-started:
      throw "INVALID_STATE"
    driver_.logger.info "disconnecting from the location service on the modem"
    gnss := driver_ as Gnss
    try:
      gnss.gnss_stop
    finally:
      gnss-started = false
      close_driver

