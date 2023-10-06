// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api.state

service_/CellularStateServiceClient? ::= (CellularStateServiceClient).open
    --if_absent=: null

class SignalQuality:
  power/float?
  quality/float?
  constructor --.power --.quality:

quality -> SignalQuality?:
  service := service_
  if not service: throw "cellular unavailable"
  return service.quality

iccid -> string?:
  service := service_
  if not service: throw "cellular unavailable"
  return service.iccid

model -> string?:
  service := service_
  if not service: throw "cellular unavailable"
  return service.model

version -> string?:
  service := service_
  if not service: throw "cellular unavailable"
  return service.version
