import system.services
import ..location show Location GnssLocation

location-service/LocationService ::= (LocationServiceClient).open as LocationService

interface LocationService:
  static SELECTOR ::= services.ServiceSelector
      --uuid="b833ce53-3c2c-400c-be82-6538d2409f2d"
      --major=0
      --minor=1

  start config/Map
  static START-INDEX ::= 2000

  read-location -> GnssLocation?
  static READ-LOCATION-INDEX ::= 2001

  stop
  static STOP-INDEX ::= 2002


class LocationServiceClient extends services.ServiceClient implements LocationService:
  static SELECTOR ::= LocationService.SELECTOR
  constructor selector/services.ServiceSelector=SELECTOR:
    assert: selector.matches SELECTOR
    super selector

  start config/Map?:
    invoke_ LocationService.START-INDEX config

  read-location -> GnssLocation?:
    result := invoke_ LocationService.READ-LOCATION-INDEX null
    if not result: return null
    return GnssLocation.deserialize result

  stop:
    invoke_ LocationService.STOP-INDEX null
