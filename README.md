# Cellular

This package contains cellular drivers for a selection of cellular modems written
in the [Toit language](https://toitlang.org). The drivers are open source under a
[permissive license](LICENSE) and they are easy to encapsulate and run in separate
containers, providing a high-level network interface for standalone applications.

## Supported modems

### Quectel

- [BG96](src/modules/quectel/bg96.toit)

### Sequans

- [Monarch](src/modules/sequans/monarch.toit)

### u-blox

- [Sara R4](src/modules/ublox/sara_r4.toit)
- [Sara R5](src/modules/ublox/sara_r5.toit)
