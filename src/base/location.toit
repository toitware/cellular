// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be found
// in the LICENSE file.

import encoding.tison

/**
A location in a geographical coordinate system.
A location is comprised of a latitude and a longitude.
*/
class Location:
  /** The latitude. */
  latitude/float
  /** The longitude. */
  longitude/float

  /** Constructs a location with the given $latitude and $longitude. */
  constructor .latitude/float .longitude/float:

  /**
  Constructs a location from the given bytes.

  This is the inverse of $to-byte-array.
  */
  constructor.deserialize bytes/ByteArray:
    values := tison.decode bytes
    latitude = values[0]
    longitude = values[1]

  /** See $super. */
  stringify:
    return "$(component-string_ latitude "N" "S"), $(component-string_ longitude "E" "W")"

  /**
  Serializes this location.

  Produces valid input to $Location.deserialize.
  */
  to-byte-array:
    return tison.encode [latitude, longitude]

  component-string_ value/float positive/string negative/string -> string:
    return "$(%3.5f value.abs)$(value >= 0 ? positive : negative)"

  /** See $super. */
  operator == other:
    if other is not Location: return false
    return latitude == other.latitude and longitude == other.longitude

  /** The hash code of this location. */
  hash-code -> int:
    return latitude.bits * 13 + longitude.bits * 17

/**
A Globale Navigation Satellite System (GNSS) location.

A GNSS location is comprised of a location, an altitude, a time, and
  an accuracy of the given location.
*/
class GnssLocation extends Location:
  /** The time (UTC) when this location was recorded. */
  time/Time
  /** The horizontal accuracy. */
  horizontal-accuracy/float ::= 0.0
  /** The vertical accuracy. */
  vertical-accuracy/float ::= 0.0
  /** The altitude relative to the median sea level. */
  altitude-msl/float ::= 0.0

  /** Constructs a GNSS location from the given parameters. */
  constructor location .altitude-msl .time .horizontal-accuracy .vertical-accuracy:
    super location.latitude location.longitude


  /**
  Constructs a GNSS location from the given bytes.

  This is the inverse operation of $to-byte-array.
  */
  constructor.deserialize bytes/ByteArray?:
    values := tison.decode bytes
    return GnssLocation
      Location values[0] values[1]
      values[2]
      Time.deserialize values[3]
      values[4]
      values[5]

  /**
  Serializes this GNSS location.

  This is the inverse operation of $GnssLocation.deserialize.
  */
  to-byte-array:
    return tison.encode [
      latitude,
      longitude,
      altitude-msl,
      time.to-byte-array,
      horizontal-accuracy,
      vertical-accuracy,
    ]

  /** See $super. */
  operator == other:
    if other is not GnssLocation: return false
    return super other and
        time == other.time and
        horizontal-accuracy == other.horizontal-accuracy and
        vertical-accuracy == other.vertical-accuracy and
        altitude-msl == other.altitude-msl

  /** The hash code. */
  hash-code -> int:
    return (super + time.hash-code * 19 + horizontal-accuracy * 23
        + vertical-accuracy * 29 + horizontal-accuracy * 37 + altitude-msl * 41).to-int
