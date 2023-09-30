// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api.hardware

service_/HardwareServiceClient? ::= (HardwareServiceClient).open
    --if_absent=: null

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