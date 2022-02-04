// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import at

/** The locker wraps an $at.Locker and removes all unwanted trace. */
class Locker:
  at_/at.Locker
  default_should_trace/Lambda

  constructor at_session/at.Session .default_should_trace:
    at_ = at.Locker at_session

  do [block] --should_trace=default_should_trace -> any:
    catch --trace=(: should_trace.call it) --unwind=true:
      return at_.do block
    unreachable
