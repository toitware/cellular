// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Custom service provider for the SIM800L on the LilyGO T-Call board.

The T-Call board has a power management IC (IP5306) controlled by GPIO 23
  that must be enabled before the SIM800L module can be used. This service
  provider turns the power IC on when the network is opened and off when
  it is closed, following the pattern from the Olimex PoE Ethernet example.

Install as a container:
$ jag container install sim800l examples/sim800l-tcall.toit
*/

import gpio
import net

import cellular.modules.simcom.sim800l show Sim800lService

class Sim800lTCallService extends Sim800lService:
  power-control_/gpio.Pin? := null

  open-network -> net.Interface:
    power-control_ = gpio.Pin --output 23
    power-control_.set 1
    return super

  close-network network/net.Interface -> none:
    try:
      super network
    finally:
      if power-control_:
        power-control_.close
        power-control_ = null

main:
  service := Sim800lTCallService
  service.install
