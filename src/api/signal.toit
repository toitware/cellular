// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services
import ..signal show SignalQuality

interface SignalService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="d2d3a535-ae1a-4846-9227-51769a9de87f"
      --major=0
      --minor=1

  quality -> SignalQuality?
  static QUALITY_INDEX ::= 0

class SignalServiceClient extends services.ServiceClient implements SignalService:
  static SELECTOR ::= SignalService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  quality -> SignalQuality?:
    result := invoke_ SignalService.QUALITY_INDEX null
    return result ? (SignalQuality --power=result[0] --quality=result[1]) : null