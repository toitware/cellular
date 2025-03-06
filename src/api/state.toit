// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services
import ..state show SignalQuality

interface CellularStateService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="432cfa7f-ab2a-4f9f-b10c-fa2e2b693a79"
      --major=0
      --minor=1

  quality -> SignalQuality?
  static QUALITY-INDEX ::= 0

  iccid -> string?
  static ICCID-INDEX ::= 1

  model -> string?
  static MODEL-INDEX ::= 2

  version -> string?
  static VERSION-INDEX ::= 3

class CellularStateServiceClient extends services.ServiceClient implements CellularStateService:
  static SELECTOR ::= CellularStateService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  quality -> SignalQuality?:
    result := invoke_ CellularStateService.QUALITY-INDEX null
    return result ? (SignalQuality --power=result[0] --quality=result[1]) : null

  iccid -> string?:
    return invoke_ CellularStateService.ICCID-INDEX null

  model -> string?:
    return invoke_ CellularStateService.MODEL-INDEX null

  version -> string?:
    return invoke_ CellularStateService.VERSION-INDEX null
