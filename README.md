# agon-serial-bios

An interrupt-driven UART1 BIOS and SRAM-resident RAM test for the Agon eZ80.

## Project contents

- `bios/` contains the BIOS sources, API documentation, and linker script.
- `src/main.c` and the root `Makefile` are the AgonDev-dependent BIOS loader.
- `test/` contains the RST 10h API test program and emulator harness.
- `examples/` contains `helloserial`, an XMODEM-loaded example program.
- `run.sh` starts the emulator and Minicom through a temporary virtual serial
  pair; `--xmodem FILE` sends a file with `sx` before opening Minicom.

## Build

The build expects the AgonDev toolchain: `ez80-none-elf-as` and
`ez80-none-elf-ld` in the parent AgonDev `bin/` directory, plus
`agondev-config` and `make` on `PATH`.

```sh
./build.sh
```

This creates `bin/EZ80BIOS.bin` (exactly 8192 bytes), the 8-byte
`bin/bios_reset_stub.bin` for address `0x000000`, `bin/biosloader.bin`, and
`bin/helloserial.bin`. The reset stub starts with `JP.LIL bios_soft_start`;
the soft initializer also copies all eight RST stubs into low external SRAM.
The build copies the binaries to `sdcard/` and writes an `autoexec.txt` that
loads and runs the BIOS loader. Generated card contents are ignored by Git;
rebuilding overwrites them.

## Run and test

The runtime script requires `fab-agon-emulator`, `socat`, and `minicom`, plus
one of `st`, `ghosty`/`ghostty`, `alacritty`, or `xterm` on `PATH`:

```sh
./run.sh
```

To upload the hello test with XMODEM before Minicom opens:

```sh
./run.sh --xmodem bin/helloserial.bin
```

This requires `sx` from `lrzsz`. Optional emulator arguments can also be passed
through, for example:

```sh
./run.sh --debugger
```

The script uses this repository's `sdcard/` directory, connects emulator
UART1 to Minicom at 115200 baud, and starts the emulator before the terminal in
normal mode. `--no-audio` is passed to the emulator at launch.

BIOS testing uses a **patched Fab Agon Emulator** that correctly identifies
and dispatches interrupt causes on UART0 and UART1. The patch also advances
peripherals while the CPU is halted and wakes the CPU when an interrupt is
accepted; these changes are tracked in [Fab Agon Emulator PR #89](https://github.com/tomm/fab-agon-emulator/pull/89).

To test XMODEM, send `bin/helloserial.bin` from Minicom using Xmodem while the
BIOS is waiting for a transfer. Press a key at the BIOS prompt after the
transfer; the program prints `Hello, world!` and enters the idle loop.

The UART1 end-to-end BIOS smoke test reached the BIOS startup output over the
serial link. BIOS output uses CRLF so terminal emulators such as Minicom return
to the left margin on each new line.

## eZ80 interrupt and memory references

The official [Zilog eZ80 CPU User Manual (UM007715-0415)](https://www.zilog.com/docs/um0077.pdf)
describes the CPU interrupt modes. For eZ80F92 interrupt-vector construction,
see the eZ80F92/eZ80F93 Product Specification (PS015317-0120), “Interrupt
Controller” section, printed pages 45–47. It specifies that `I` is the
Interrupt Page Address Register and the interrupting peripheral supplies its
fixed 8-bit value on the internal `IVECT[7:0]` bus. The table-entry address is
`{I[7:0], IVECT[7:0]}`; the ISR's 16-bit address is stored little-endian there.

In ADL mode the CPU fetches that 16-bit ISR address, sets `PC[15:0]` to it,
and runs with `PC[23:16] = 0`; it does not fetch a 24-bit ISR address. In Z80
mode, the corresponding table entry is in the MBASE page and execution is
effectively at `{MBASE, PC[15:0]}`. See Product Specification Table 12.

Defined eZ80F92 peripheral vector values:

- `0x08` flash; `0x0A`–`0x14` timers 0–5
- `0x16` RTC; `0x18` UART0; `0x1A` UART1; `0x1C` I²C; `0x1E` SPI
- `0x30`–`0x3E` Port B bits 0–7
- `0x40`–`0x4E` Port C bits 0–7
- `0x50`–`0x5E` Port D bits 0–7

Other offsets in this range are reserved or unassigned by `ez80f92.h`. The
vector table base is controlled by the CPU's `I` register; consult the manual
for the active ADL/MADL mode and device-specific details.

The F92 product specification (PS015317-0120, printed pages 190–192) says the
8 KiB internal SRAM occupies `{RAM_ADDR_U, 0xE000}` through
`{RAM_ADDR_U, 0xFFFF}` and takes priority over memory chip selects on overlap.
With `RAM_ADDR_U = 0`, internal SRAM occupies `0x00E000–0x00FFFF` and shadows
that part of external SRAM.

The BIOS reserves the entire first 64 KiB (`0x000000–0x00FFFF`) for system use.
`CS0_LBR`/`CS0_UBR` map the 512 KiB external SRAM to pages `0x00`–`0x07`
(`0x000000–0x07FFFF`); programs and XMODEM payloads start at `0x010000`.
The RST stubs occupy the low addresses, while the on-chip SRAM overlay holds
the BIOS code, active peripheral IVT, hot ISRs, rings, and stack. The hard
initializer disables Flash, restores the on-chip SRAM mapping, and maps CS0;
the soft initializer installs RST stubs and default IVT entries. At startup,
the BIOS copies a diagnostic string to `0x010000` and prints it from external
SRAM through the BIOS's internal string-output routine and UART1.

## VSync interrupt at handoff

`src/main.c:bios_handoff()` disables CPU interrupts, clears the pending Port B
bit 1 edge, and returns PB1 to ordinary input mode before transferring control
to the BIOS. The soft initializer repeats the PB1 cleanup on warm restart. MOS
leaves PB1 configured for rising-edge VSync; this BIOS uses UART1 and does not
install a VSync handler.

## UART1 interrupt driver

`bios/EZ80BIOS.s` configures UART1 for 115200 8N1 with 16-byte FIFOs and services
its vectored interrupt (`I=0xFB`, `IVECT 0x1A`; active table at `0xFB00` in
internal SRAM, just before ring metadata at `0xFC00`). The soft initializer
restores the default table before enabling interrupts. The ISR drains all RX bytes into
`bios_rs_ring` and fills the TX FIFO in bursts from `bios_ts_ring`. The
256-byte rings reserve one slot to distinguish full from empty, so each holds
up to 255 bytes. RX overflow drops the byte and increments the wrapping
`bios_rs_overflow` counter.

## Public call interface

Client code uses the software `RST 10h` entry rather than linking against BIOS
routine or data symbols. Set `A` to an operation and execute unprefixed
`RST 10h`;
`A` is always clobbered (and may contain an operation result). The dispatcher
returns through the RST call frame. Carry and other flags are operation-specific.
The BIOS's internal routines remain implementation details.

Operation definitions and register contracts are documented in [`bios/BIOS_API.md`](bios/BIOS_API.md). The dispatcher operation IDs are:

| Operation | Register arguments | Result |
| --- | --- | --- |
| `BIOS_OP_PUTCHAR` | `C` = character | blocking output |
| `BIOS_OP_GETCHAR` | — | character in `A` |
| `BIOS_OP_PEEK` | — | byte in `A`; carry set if RX ring is empty |
| `BIOS_OP_NREAD` | `HL` = destination, `BC` = byte count | blocking binary read |
| `BIOS_OP_PUTS` | `HL` = NUL-terminated string | blocking string output |
| `BIOS_OP_XMODEM_RX` | `HL` = destination, `BC` = maximum size in bytes | status in `A` (`0` success, nonzero error) |
| `BIOS_OP_TX_PUT` | `C` = byte | carry set if TX ring is full |
| `BIOS_OP_RX_GET` | — | byte in `A`; carry set if RX ring is empty |
| `BIOS_OP_WAIT` | — | busy-wait delay |
| `BIOS_OP_HALT` | — | does not return; enters the idle loop |
| `BIOS_OP_CALL_HL` | `HL` = function pointer | tail-calls the function through the RST frame |
| `BIOS_OP_VECTOR_ADD` | `B` = IVECT, `HL` = handler | register a PRT0 extension |
| `BIOS_OP_VECTOR_REMOVE` | `B` = IVECT, `HL` = handler | unregister a PRT0 extension |

`HL` and `DE` carry addresses, and `BC` carries counts. Unless a result is
specified above, callers must not depend on register or flag preservation.
Vector operations currently support PRT0 (`IVECT=0x0A`) with eight slots;
duplicate handler addresses are allowed and one removal clears all copies.
Occupied slots run in reverse slot order. Handlers may use the registers
saved by the ISR (`AF`, `BC`, `DE`, `HL`, `IX`, `IY`) and must end with
`pop hl; jp (hl)` to
chain to the next handler or return to the ISR. They must not execute `EI` or
terminate with `RET` / `RETI`; the BIOS completes the interrupt. See
`bios/BIOS_API.md` for statuses and details.
RST `00h` is the non-returning soft restart; RST `08h`, `18h`, `20h`, `28h`,
`30h`, and `38h` enter the idle loop. Interrupt handlers preserve the
interrupted register set.

### BIOS API test suite

`test/testbios.s` is a loadable program that exercises every public operation.
Build it with `./build.sh`; the result is `bin/testbios.bin`. Run the
automated emulator test with `python3 test/testbios.py`. The harness requires `sx` (lrzsz) and
`fab-agon-emulator` on `PATH`; pass `--emulator`, `--vdp`, and/or `--mos` when
the emulator or its firmware is installed elsewhere. It uses `sx` for both the
initial program load and the suite's XMODEM receive test. It also verifies
eight chained PRT0 slots, duplicate registration, full-table rejection,
remove-all behavior, and stopping callbacks after removal.

## XMODEM-CRC receive

At startup the BIOS prints `Waiting for XMODEM at 0x010000` and internally
calls its receiver with `HL=0x010000` and `BC=0x070000`, the remaining external
RAM capacity. Client programs can invoke the same operation through
`BIOS_OP_XMODEM_RX`, passing their destination in `HL` and maximum writable size
in `BC`. The pre-handshake output intentionally
avoids an uppercase `C`, which an XMODEM sender interprets as a CRC request. The
routine receives 128-byte XMODEM frames through the UART1 RX ring. PRT0 ticks
every 10 ms, increments the 24-bit `bios_uptime_10ms` value, and drains residual
hardware RX FIFO bytes into the ring. During the handshake, the BIOS registers
`__io_xmodem_start` through `VECTOR_ADD`, without replacing the IVT entry. The
hook discards unrelated RX bytes, leaves SOH/CAN/EOT queued, and resends `C`
every 256 ticks (2,560 ms). It unregisters itself when a start control byte is
detected; the receiver also removes it on every exit. Other registered handlers
remain in the chain.

Each frame's payload is written to external SRAM and its two CRC bytes are
checked with CRC-16/XMODEM (polynomial `0x1021`, initial value `0x0000`,
non-reflected, no final XOR; high CRC byte first); CRC bytes are not stored. A
frame is accepted only if all 128 payload bytes fit within both the caller's
remaining capacity and external SRAM. If not, the receiver sends CAN and returns
an error without writing that frame. Bad CRC frames receive NAK; valid frames
receive ACK, including retransmitted duplicates. EOT is ACKed; the BIOS prints
`Load complete` and prompts `Press R to run`.
It ignores other input, clears `A` after `R`/`r`, then jumps to `0x010000`.

Reads block on UART/timer interrupts; there are no receive timeouts. XMODEM
transmits complete 128-byte blocks and does not include the exact file length, so
any final-block padding is also present in memory. The receiver can store up to
3584 blocks (458,752 payload bytes) from the startup destination; client
capacities must account for whole frames.

UART1 RTS is active-low. The BIOS routes PC0–PC2 to UART1 and uses hysteresis:
it deasserts RTS below 33 free RX-ring slots and reasserts it only at 133 free
slots, enough room for a full 133-byte XMODEM/CRC packet. TX does not check CTS,
so it works with UART adapters that do not provide modem-status signals.

### RX/TX function tree

```text
bios_entry (hard initializer)
├─ disable Flash; restore internal SRAM and map external SRAM at 0x000000
└─ bios_soft_start
   ├─ reset stack; restore RST stubs and the peripheral IVT defaults
   ├─ initialize UART1/PRT0 and print startup messages
   └─ io_xmodem_rx (HL=0x010000, BC=0x070000)
      ├─ __io_xmodem_start (registered PRT0 extension; resend 'C', peek RX ring)
      ├─ BIOS_OP_GETCHAR (HALT while rs is empty)
      ├─ receive complete 128-byte frames within BC and physical SRAM bounds
      ├─ CRC-16/XMODEM check ──> ACK or NAK
      └─ EOT ──> print completion and Press R prompt
         └─ wait for R/r, zero A, jump to 0x010000

transfer error ──> print failure, then __bios_idle

__bios_uart1_isr (UART1 vector 0x1A)
├─ RX causes ──> drain UART FIFO into rs, update RTS
└─ TX-empty ──> fill UART FIFO from ts

__io_xmodem_start (registered PRT0 extension)
├─ discard unrelated bytes; leave SOH/CAN/EOT queued
├─ gate receiver with an atomic start-flag byte
├─ resend 'C' on the 256-tick schedule
└─ pop HL / JP (HL) to the next extension or timer ISR

__bios_timer0_isr (PRT0 vector 0x0A; 10 ms)
├─ increment bios_uptime_10ms
└─ drain residual UART1 RX FIFO into rs
```

