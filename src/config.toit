import gpio show Pin InvertedPin
import net.cellular
import log.level

class CellularConfiguration:
  uart-rx/Pin? := ?
  uart-tx/Pin? := ?
  uart-cts/Pin? := ?
  uart-rts/Pin? := ?
  uart-baud-rates/List? := ?
  uart-high-priority/bool := ?
  power/Pin? := ?
  reset/Pin? := ?
  apn/string := ?
  rats/List? := ?
  bands/List? := ?
  log-level/int? := ?

  owned_/List := []

  /**
  Notice that $power and $reset should be active high. If your cellular module defines these as active low, then
  use $InvertedPin.
  */
  constructor
      --.uart-rx=null
      --.uart-tx=null
      --.uart-cts=null
      --.uart-rts=null
      --.power=null
      --.reset=null
      --.uart-baud-rates=null
      --.uart-high-priority=false
      --.apn=""
      --.rats=null
      --.bands=null
      --.log-level=level.INFO-LEVEL:

  static RX-OWNED_ ::= 0
  static TX-OWNED_ ::= 1
  static RTS-OWNED_ ::= 2
  static CTS-OWNED_ ::= 3
  static POWER-OWNED_ ::= 4
  static RESET-OWNED_ ::= 5

  update-from-map_ config/Map?:
    if not config: return

    uart-rx = update-pin-from-map_ config cellular.CONFIG-UART-RX RX-OWNED_ uart-rx
    uart-tx = update-pin-from-map_ config cellular.CONFIG-UART-TX TX-OWNED_ uart-tx
    uart-cts = update-pin-from-map_ config cellular.CONFIG-UART-CTS CTS-OWNED_ uart-cts
    uart-rts = update-pin-from-map_ config cellular.CONFIG-UART-RTS RTS-OWNED_ uart-rts

    power = update-pin-from-map_ config cellular.CONFIG-POWER POWER-OWNED_ power
    reset = update-pin-from-map_ config cellular.CONFIG-RESET RESET-OWNED_ reset

    baud-rates/List? := config.get cellular.CONFIG-UART-BAUD-RATE
        --if-present=: it is List ? it : [it]
    if baud-rates: uart-baud-rates = baud-rates

    high-priority/bool := config.get cellular.CONFIG-UART-PRIORITY
        --if-present=: it == cellular.CONFIG-PRIORITY-HIGH
        --if-absent=: false
    if high-priority:
      uart-high-priority = high-priority

    if config-apn := config.get cellular.CONFIG_APN: apn = config-apn
    if config-bands := config.get cellular.CONFIG_BANDS: bands = config-bands
    if config-rats := config.get cellular.CONFIG_RATS: rats = config-rats

  update-pin_from-map_ config/Map key/string owned-indicator existing/Pin?:
    config-pin := pin_ config key
    if not config-pin: return existing
    owned_.add owned-indicator
    return config-pin

  static pin_ config/Map key/string -> Pin?:
    value := config.get key
    if not value: return null
    if value is int: return Pin value
    if value is not List or value.size != 2:
      throw "illegal pin configuration: $key == $value"

    pin := Pin value[0]
    mode := value[1]
    if mode != cellular.CONFIG_ACTIVE_HIGH: pin = InvertedPin pin
    pin.configure --output --open_drain=(mode == cellular.CONFIG_OPEN_DRAIN)
    pin.set 0  // Drive to in-active.
    return pin

  close-owned-pins_:
    owned_.do:
      if it == RX-OWNED_:
        uart-rx.close
        uart-rx = null

      if it == TX-OWNED_:
        uart-tx.close
        uart-tx = null

      if it == CTS-OWNED_:
        uart-cts.close
        uart-cts = null

      if it == RTS-OWNED_:
        uart-rts.close
        uart-rts = null

      if it == POWER-OWNED_:
        power.close
        power = null

      if it == RESET-OWNED_:
        reset.close
        reset = null
