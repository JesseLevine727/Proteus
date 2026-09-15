# Proteus Protocol Targets

Proteus is a protocol emulator: protocols are **firmware programs** on the
RISC-V micro-core, with hardware accelerators introduced only where firmware
cannot meet timing. This document is the single source of truth for which
protocols we target, how they are implemented, and how each is verified.

## Matrix

| Protocol | Pins | Rate | Implementation | Phase | Verification |
|---|---|---|---|---|---|
| UART | 2 (TX/RX) | ≤ ~1 Mbaud | firmware | 1, 3 | golden model + loopback |
| SPI | 4 (SCK/MOSI/MISO/CS) | ≤ few MHz | firmware | 3 | loopback vs golden model |
| I2C | 2 (SDA/SCL) | 100 / 400 kHz | firmware (open-drain emulation) | 3 | loopback vs golden model |
| CAN (low speed) | 2 (TX/RX) + transceiver | ≤ 250 kbit/s | firmware | 3 | two-node sim (wired-AND bus) |
| CAN 2.0B (full) | 2 (TX/RX) + transceiver | ≤ 1 Mbit/s | **hardware controller** | 6 | two-node sim + FPGA + USB-CAN adapter |
| JTAG | 4 (TCK/TMS/TDI/TDO) | ≤ ~10 MHz | firmware host and/or TAP target | 4 | formal TAP FSM + state traces |
| SWD | 2 (SWCLK/SWDIO) | ≤ ~10 MHz | firmware | later | transaction traces |
| PS/2 | 2 (CLK/DATA) | ~10–16 kHz | firmware | later | device model |
| Ethernet 10BASE-T | MII (~12) + external PHY | 10 Mbit/s | **hardware MAC** | 6 | loopback / MII PHY + reference frames |

## Pin budget

Tiny Tapeout provides 24 signals (`ui_in` ×8, `uo_out` ×8, `uio` ×8). Protocols
are **time-multiplexed**: the pin assignment is itself firmware configuration,
which is the point of the chip. Full MII for Ethernet consumes most of the
budget, so Ethernet and a full pin-out of every other protocol are mutually
exclusive at any instant.

| Protocol set | Pins used |
|---|---|
| UART + SPI + I2C + JTAG + CAN | 14 |
| Ethernet MII alone | ~12 |

## Analog requirements

Proteus is a digital chip; analog layers are external:

| Protocol | External part | Pins |
|---|---|---|
| CAN | transceiver (SN65HVD230 / TJA1050 / MCP2551) | 2 |
| Ethernet | 10BASE-T PHY (MII) + magnetics/RJ45 | ~12 |
| I2C | pull-up resistors | 2 |
| UART/SPI/JTAG | none | — |

## Why CAN is split into two tiers

CAN's dominant/recessive arbitration and bit stuffing make pure firmware
bit-banging practical only at lower rates:

- At **125 kbit/s** (8 µs/bit) and a ~50 MHz core, a bit is ~400 cycles —
  comfortable for firmware.
- At **1 Mbit/s** (1 µs/bit), a bit is ~50 cycles, and arbitration/bit
  stuffing must be handled cycle-by-cycle — this needs a hardware controller.

So firmware CAN (≤250 kbit/s) is the guaranteed deliverable and proves the
firmware thesis; the hardware CAN 2.0B controller is an area-gated stretch.
CAN FD is out of scope.
