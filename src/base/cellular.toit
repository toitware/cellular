// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log
import net
import system.base.network show ProxyingNetworkServiceProvider

import .at as at
import .location show GnssLocation
import ..state show SignalQuality

RAT_LTE_M ::= 1
RAT_NB_IOT ::= 2
RAT_GSM ::= 3

/**
Cellular driver interface for
*/
interface Cellular:
  static DEFAULT_BAUD_RATE/int ::= 115_200

  logger -> log.Logger

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

  configure apn/string --bands/List?=null --rats/List?=null

  /**
  Connect to the service using the optional operator.
  */
  connect --operator/Operator?=null -> none

  /**
  Connect to the service after a PSM wakeup.
  */
  connect_psm -> none

  /**
  Scan for operators.
  */
  scan_for_operators -> List

  get_connected_operator -> Operator?

  open_network --provider/ProxyingNetworkServiceProvider?=null -> net.Interface

  detach -> none

  close -> none
  close_uart -> none

  signal_strength -> float?
  signal_quality -> SignalQuality?

  wait_for_ready -> none

  enable_radio -> none

  disable_radio -> none

  power_on -> none

  power_off -> none

  reset -> none

  on_aborted_command session/at.Session command/at.Command -> none

  is_powered_off -> bool?

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
