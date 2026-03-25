# SIM800L Driver

Driver for the SIMCom SIM800L GSM/GPRS (2G) module.

## Hardware requirements

The SIM800L operates at **3.7-4.2V** and can draw up to **2A** during
transmission bursts. Make sure your power supply can handle this.

- Do **not** power the module from the ESP32's 3.3V or 5V pins. The 3.3V is
  too low, and 5V exceeds the module's maximum voltage rating.
- A LiPo battery (3.7V, 1200mAh+) or a 2A-capable DC-DC converter is recommended.
- Some boards (like the LilyGO T-Call) include a power management IC.
- The SIM800L uses ~2.8V logic levels. The ESP32's 3.3V TX cannot be connected
  directly to the SIM800L RX — use a voltage divider or level shifter.

### Pin connections

| SIM800L Pin | Description |
|-------------|-------------|
| VCC | 3.7-4.2V power supply |
| GND | Ground |
| TXD | Module transmit → ESP32 UART RX |
| RXD | Module receive ← ESP32 UART TX |
| RST | Active-low reset (pull low to reset) |
| PWRKEY | Power toggle (pulse low >1s to toggle on/off) |

## Usage

### Installation

Install the driver as a container on the device:

```
jag container install sim800l src/modules/simcom/sim800l.toit
```

### LilyGO T-Call board

The T-Call board has a power management IC (IP5306) controlled by GPIO 23
that must be enabled before the SIM800L module can be used. The T-Call
example provides a custom service provider that manages the power IC
automatically — it enables the IC when the network is opened and disables
it when all clients disconnect. Install the T-Call wrapper instead:

```
jag pkg install --project-root examples/
jag container install sim800l examples/sim800l-tcall.toit
```

**T-Call pinout:**

| Function | GPIO |
|----------|------|
| UART TX | 27 |
| UART RX | 26 |
| RST | 5 |
| PWRKEY | 4 |
| POWER_ON | 23 |

### Configuration

```toit
import net.cellular

config ::= {
  cellular.CONFIG-APN: "your-apn",
  cellular.CONFIG-UART-TX: 27,
  cellular.CONFIG-UART-RX: 26,
  cellular.CONFIG-POWER: [4, cellular.CONFIG-ACTIVE-HIGH],   // PWRKEY
  cellular.CONFIG-RESET: [5, cellular.CONFIG-ACTIVE-LOW],    // RST
  cellular.CONFIG-LOG-LEVEL: log.INFO-LEVEL,
}

network := cellular.open config
```

### Example

See [examples/sim800l.toit](../../../examples/sim800l.toit) for a complete
example that does an HTTP GET over the cellular network.

## Limitations

- 2G (GSM/GPRS) only — no LTE support.
- Maximum 6 simultaneous TCP/UDP connections. Opening a 7th connection
  throws a `ResourceExhaustedException`.
- Maximum ~1460 bytes per single AT send command. TCP writes are
  automatically chunked by the driver; UDP sends that exceed the MTU
  (1460 bytes) throw an error.
- No hardware flow control (RTS/CTS) support in most configurations.
- The PWRKEY pin toggles power on/off, so the driver only pulses it once
  during initialization to avoid toggling the module off.
