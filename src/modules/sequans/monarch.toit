// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log
import uart
import gpio

import .sequans

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

/**
This is the driver and service for the Sequans Monarch module. The easiest
  way to use the module is to install it in a separate container and let
  it provide its network implementation as a service.

You can install the service through Jaguar:

$ jag container install cellular-monarch src/monarch.toit

and you can run the example afterwards:

$ jag run examples/monarch.toit

Happy networking!
*/
main:
  service := MonarchService
  service.install

// --------------------------------------------------------------------------

class MonarchService extends CellularServiceProvider:
  constructor:
    super "sequans/monarch" --major=0 --minor=1 --patch=0

  create-driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --rx/gpio.Pin?
      --tx/gpio.Pin?
      --rts/gpio.Pin?
      --cts/gpio.Pin?
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --baud-rates/List?:
    return Monarch port logger
        --power=power
        --reset=reset
        --uart-baud-rates=baud-rates or [921_600]

/**
Driver for Sequans Monarch, GSM communicating over NB-IoT & M1.
*/
class Monarch extends SequansCellular:
  power_/gpio.Pin?
  reset_/gpio.Pin?
  reset-last_/int? := null

  constructor port/uart.Port logger/log.Logger
      --power/gpio.Pin?
      --reset/gpio.Pin?
      --uart-baud-rates/List:
    power_ = power
    reset_ = reset
    super port
        --logger=logger
        --uart-baud-rates=uart-baud-rates
        --use-psm=false

  network-name -> string:
    return "cellular:monarch"

  power-on -> none:
    if not reset_: return
    now := Time.monotonic-us --since-wakeup
    if reset-last_ and now - reset-last_ < 5_000_000: return
    reset-last_ = now
    logger.debug "power-on: pulling reset pin"
    reset_.set 1
    sleep --ms=10
    reset_.set 0
    // TODO(kasper): Consider waiting for +SYSSTART.

  on-connected_ session/at.Session:
    // Do nothing.

  on-reset session/at.Session:
    // Do nothing.
