// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import gpio
import log
import uart

import .luat

import ...base.at as at
import ...base.base as cellular
import ...base.cellular as cellular
import ...base.service show CellularServiceProvider

main:
  service := Air780eService
  service.install

// --------------------------------------------------------------------------

class Air780eService extends CellularServiceProvider:
  constructor:
    super "luat/air780e" --major=0 --minor=1 --patch=0

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
    return Air780e port logger
        --power-pin=power
        --baud-rates=baud-rates

/**
Driver for the AirM2M Air780E and Air780EG LTE Cat-1 modems.

The Air780E boots as soon as it is powered on. If the board exposes a way
  to gate the module's power supply from a GPIO, wire it to $power-pin and
  the driver will use it to cold-boot the modem and to fall back to a hard
  power-off if the AT-level CPOWD doesn't take. $power-pin is optional —
  if the module is permanently powered (e.g., on a dev board with a
  dedicated PWRKEY circuit), leave it null and the driver will rely on
  CPOWD for shutdown.
*/
class Air780e extends LuatCellular:
  power-pin/gpio.Pin?

  constructor port/uart.Port logger/log.Logger
      --.power-pin=null
      --baud-rates/List?:
    super port
        --logger=logger
        --uart-baud-rates=baud-rates or [115_200]
        --use-psm=false

  network-name -> string:
    return "cellular:air780e"

  on-reset session/at.Session:
    // Full functionality + reset. The modem reboots and re-acquires the
    // network.
    session.set "+CFUN" [1, 1]

  powered-on_ := false

  power-on -> none:
    if powered-on_: return
    powered-on_ = true
    if power-pin:
      critical-do --no-respect-deadline:
        power-pin.set 1
        // Allow time for the modem to boot and accept AT commands.
        sleep --ms=3000

  power-off -> none:
    if not power-pin: return
    powered-on_ = false
    critical-do --no-respect-deadline:
      power-pin.set 0
      // Brief pause to ensure capacitors discharge before any subsequent
      // power-on attempt.
      sleep --ms=500
