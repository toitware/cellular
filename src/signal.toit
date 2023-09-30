// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api.signal

service_/SignalServiceClient? ::= (SignalServiceClient).open
    --if_absent=: null

class SignalQuality:
  power/float?
  quality/float?
  constructor --.power --.quality:

quality -> SignalQuality?:
  service := service_
  if not service: throw "cellular unavailable"
  return service.quality