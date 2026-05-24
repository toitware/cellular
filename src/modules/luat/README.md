# Air780E / Air780EG Driver

Driver for the AirM2M (Luat) **Air780E** and **Air780EG** LTE Cat-1 modules.
The two parts are pin-compatible; the `EG` variant adds a built-in GNSS
receiver (a separate GNSS antenna is required for a fix).

The driver speaks the SIMCom-style multi-IP AT command set
(`CIPMUX` / `CIPSTART` / `CIPRXGET` / `CIPSHUT` / `CDNSGIP`) and shares its
TCP/UDP/DNS implementation with the [SIM800L driver](../simcom/) through
[`src/base/cip.toit`](../../base/cip.toit).

## Module pinout

The small Air780E breakout has 12 pins, 6 per side:

```
              +-----------------+
         5V --|                 |-- 5V
        GND --|                 |-- GND
         DP --|     Air780E     |-- TXD
         DN --|                 |-- RXD
        NET --|                 |-- EN
        BOT --|                 |-- BAT
              +-----------------+
```

| Pin | Function | Notes |
|-----|----------|-------|
| `5V` | Main supply | Two pins, tied together internally. Powers the on-module buck converter that produces the modem's core rail. |
| `GND` | Ground | Two pins, tied internally. |
| `DP` / `DN` | USB data | Optional. Only needed if you want to talk to the modem over USB. |
| `NET` | Network status | Open-drain output. Blinks at a rate that indicates registration state — useful for an external LED, not required for the driver. |
| `BOT` | Boot / download mode | Pull low at power-on to enter the module's firmware-download mode. Leave floating in normal operation. |
| `TXD` | AT-port TX | Modem output → MCU UART RX. **This is the AT-command interface.** |
| `RXD` | AT-port RX | Modem input ← MCU UART TX. |
| `EN` | Buck-converter enable | Required when powering the module from USB (see warning below). Can be left floating when powering from `BAT`. |
| `BAT` | Battery input | Direct 4 V (3.4–4.2 V) input. Bypasses the on-module buck converter, so it draws less current than `5V`. Connect a LiPo cell or a 4 V supply. |

### USB wiring warning

If you connect `5V`, `GND`, `DP`, `DN` to a USB host, you **must** also tie
`EN` to `5V`. `EN` powers the on-module buck converter; if it is left
floating while `DP`/`DN` are driven, the modem can back-feed the data lines
and **damage the USB host**.

For the driver in this directory we only use the AT-port UART (`TXD` /
`RXD`), so the USB data lines (`DP` / `DN`) are not needed.

### Powering choices

Two clean options:

- **`5V` + `GND` + `EN` tied high.** Easiest with a 5 V supply. Higher
  current draw on the supply because of the buck converter.
- **`BAT` + `GND` only.** Feed 4 V directly. Lowest quiescent current and
  best for battery-backed setups. Leave `5V` and `EN` disconnected.

Either way the module is **always on while its supply rail is energized** —
there is no PWRKEY toggle on this footprint. If you need software
power-cycling, gate the supply rail (or `EN`) through an external switch
driven from a GPIO, then pass that GPIO as `CONFIG-POWER` in the config.
The driver will:

1. Drive the GPIO active to power the modem on.
2. Send `AT+CPOWD=1` for the graceful shutdown.
3. Drive the GPIO inactive as a hard fallback if CPOWD doesn't take.

If you don't have such a switch, leave `CONFIG-POWER` out — the driver
will rely on `AT+CPOWD=1` alone for shutdown. The downside is that after
CPOWD the modem can only be brought back by re-energizing its supply, so
the next `cellular.open` from the same boot will fail.

## Driver capabilities

- **TCP** and **UDP** sockets (up to 6 concurrent, IDs 0–5).
- **DNS** via `AT+CDNSGIP`.
- **APN auto-pick**: leave `CONFIG-APN` out and the driver uses whatever
  the SIM / network has installed in `CGDCONT` (works with auto-APN SIMs
  like simbase).
- **Soft sleep / wake** via `disable-radio` (`AT+CFUN=4`, airplane mode)
  and `enable-radio` (`AT+CFUN=1`) — no power-cycle required. See
  [`examples/air780e-sleep-wake.toit`](../../../examples/air780e-sleep-wake.toit).
- **Graceful power-off** via `AT+CPOWD=1`.

## Installation

Install the driver as a container on the device:

```
jag container install air780e src/modules/luat/air780e.toit
```

## Configuration

```toit
import net.cellular

config ::= {
  // Optional — leave out for auto-APN SIMs.
  // cellular.CONFIG-APN: "your-apn",

  cellular.CONFIG-UART-TX: 18,   // MCU TX -> module RXD
  cellular.CONFIG-UART-RX: 20,   // MCU RX <- module TXD

  // Optional. Drive a GPIO that gates the module's supply rail.
  cellular.CONFIG-POWER: [23, cellular.CONFIG-ACTIVE-HIGH],
}

network := cellular.open config
```

## Examples

- [`examples/air780e.toit`](../../../examples/air780e.toit) — HTTP GET
  over the cellular network.
- [`examples/air780e-udp.toit`](../../../examples/air780e-udp.toit) —
  SNTP query over UDP.
- [`examples/air780e-sleep-wake.toit`](../../../examples/air780e-sleep-wake.toit)
  — soft radio off / on cycle that demonstrates a low-power idle without
  power-cycling the module.

## Limitations

- 6 simultaneous TCP/UDP connections (CIPMUX multi-IP mode, IDs 0–5).
- Max ~1460 bytes per CIPSEND; TCP writes are chunked automatically,
  UDP sends above the MTU are rejected.
- No hardware flow control configured.
- The Air780E uses `AT+CFUN=4` (airplane) rather than `AT+CFUN=0` for the
  radio-off transition — `CFUN=0` disables the SIM interface on this
  firmware, which would prevent any configuration that needs the SIM.
- `AT+COPS=0,2` is rejected; the driver issues `AT+COPS=0` without the
  format parameter, so `get-connected-operator` may not return the
  operator code on this firmware.
- GNSS (Air780EG only) is not yet implemented; the AT commands
  (`AT+CGNSPWR`, `AT+CGNSINF`, `AT+CGNSURC`) are supported by the firmware
  and could be added on top of the existing driver.
