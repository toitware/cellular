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

  create_driver --port/uart.Port --power/gpio.Pin? --reset/gpio.Pin? -> cellular.Cellular:
    // TODO(kasper): If power or reset are given, we should probably
    // throw an exception.
    return Monarch port --logger=create_logger

/**
Driver for Sequans Monarch, GSM communicating over NB-IoT & M1.
*/
class Monarch extends SequansCellular:
  constructor uart --logger=log.default:
    super uart --logger=logger --default_baud_rate=921600 --use_psm=false

  on_connected_ session/at.Session:
    // Do nothing.

  on_reset session/at.Session:
    // Do nothing.
