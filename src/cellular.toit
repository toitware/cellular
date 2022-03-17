// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import net
import encoding.ubjson
import gnss_location show GnssLocation

RAT_LTE_M ::= 1
RAT_NB_IOT ::= 2
RAT_GSM ::= 3

/**
Base for Cellular drivers for embedding in the kernel.
*/
interface Cellular:
  static DEFAULT_BAUD_RATE/int ::= 115200

  use_psm -> bool
  use_psm= value/bool -> none

  /**
  Returns the model of the Cellular module.
  */
  model -> string

  /**
  Returns the version of the Cellular module.
  */
  version -> string

  /**
  Returns the ICCID of the SIM card.
  */
  iccid -> string

  is_connected -> bool

  configure apn --bands/List?=null --rats/List?=null

  /**
  Connect to the service using the optional operator.
  */
  connect --operator/Operator?=null -> bool

  /**
  Connect to the service after a PSM wakeup.
  */
  connect_psm

  /**
  Scan for operators.
  */
  scan_for_operators -> List

  get_connected_operator -> Operator?

  network_interface -> net.Interface

  detach -> none

  close -> none

  signal_strength -> float?

  wait_for_ready -> none

  enable_radio -> none

  disable_radio -> none

  power_on -> none

  /**
  Modem-specific implementation for recovering if the AT interface is unresponsive.
  */
  recover_modem -> none

  power_off -> none

  reset -> none

  on_connect_aborted -> none

class Operator:
  op/string
  rat/int?

  constructor .op --.rat=null:

  stringify -> string:
    return "$op ($rat)"

interface Gnss:
  gnss_start
  gnss_location -> GnssLocation?
  gnss_stop
