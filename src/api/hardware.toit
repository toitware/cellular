// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services
import ..signal show SignalQuality

interface HardwareService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="3909a751-0a14-4409-acf3-7310920bb42a"
      --major=0
      --minor=1

  iccid -> string?
  static ICCID_INDEX ::= 0

  model -> string?
  static MODEL_INDEX ::= 1

  version -> string?
  static VERSION_INDEX ::= 2

class HardwareServiceClient extends services.ServiceClient implements HardwareService:
  static SELECTOR ::= HardwareService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  iccid -> string?:
    return invoke_ HardwareService.ICCID_INDEX null

  model -> string?:
    result := invoke_ HardwareService.MODEL_INDEX null
    return result ? result : null

  version -> string?:
    return invoke_ HardwareService.VERSION_INDEX null
