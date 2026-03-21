// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

/**
Wrapper for the SIM800L driver on the LilyGO T-Call board.

The T-Call board has a power management IC (IP5306) that must be enabled
  via GPIO 23 before the SIM800L module can be used.

Install as a container:
$ jag container install sim800l examples/sim800l-tcall.toit
*/

import gpio
import cellular.modules.simcom.sim800l

main:
  // Enable the board's power management IC.
  power-control := gpio.Pin --output 23
  power-control.set 1

  sim800l.main
