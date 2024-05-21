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
import ...config

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
main --config/CellularConfiguration=CellularConfiguration:
  service := MonarchService --config=config
  service.install

// --------------------------------------------------------------------------

class MonarchService extends CellularServiceProvider:
  constructor --config/CellularConfiguration:
    super "sequans/monarch" --major=0 --minor=1 --patch=0 --config=config

  create_driver -> cellular.Cellular
      --logger/log.Logger
      --port/uart.Port
      --config/CellularConfiguration:
    // TODO(kasper): If power or reset are given, we should probably
    // throw an exception.
    return Monarch port logger
        --uart_baud_rates=config.uart-baud-rates or [921_600]

/**
Driver for Sequans Monarch, GSM communicating over NB-IoT & M1.
*/
class Monarch extends SequansCellular:
  constructor port/uart.Port logger/log.Logger --uart_baud_rates/List:
    super port
        --logger=logger
        --uart_baud_rates=uart_baud_rates
        --use_psm=false

  network_name -> string:
    return "cellular:monarch"

  on_connected_ session/at.Session:
    // Do nothing.

  on_reset session/at.Session:
    // Do nothing.
