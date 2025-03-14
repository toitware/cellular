// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import log
import net

import .at as at
import .location show GnssLocation
import ..state show SignalQuality

RAT-LTE-M ::= 1
RAT-NB-IOT ::= 2
RAT-GSM ::= 3

/**
Cellular driver interface for
*/
interface Cellular:
  static DEFAULT-BAUD-RATE/int ::= 115_200

  logger -> log.Logger

  use-psm -> bool
  use-psm= value/bool -> none

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
  connect-psm -> none

  /**
  Scan for operators.
  */
  scan-for-operators -> List

  get-connected-operator -> Operator?

  network-interface -> net.Interface

  detach -> none

  close -> none
  close-uart -> none

  signal-strength -> float?
  signal-quality -> SignalQuality?

  wait-for-ready -> none

  enable-radio -> none

  disable-radio -> none

  power-on -> none

  power-off -> none

  reset -> none

  on-aborted-command session/at.Session command/at.Command -> none

  is-powered-off -> bool?

class Operator:
  op/string
  rat/int?

  constructor .op --.rat=null:

  stringify -> string:
    return "$op ($rat)"

interface Gnss:
  gnss-start
  gnss-location -> GnssLocation?
  gnss-stop
