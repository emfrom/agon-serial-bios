# agon-serial-bios

An interrupt-driven UART1 BIOS and SRAM-resident RAM test for the Agon eZ80.

## Project contents

- `EZ80BIOS.s` implements the UART1 interrupt service routine, RX/TX ring
  buffers, RTS flow control, BIOS entry points, and a Minicom-compatible
  XMODEM-CRC receiver.
- `src/main.c` loads the BIOS image into internal SRAM, prepares the handoff,
  and transfers execution to it.
- `Makefile` builds `ramtest.bin`, which loads the BIOS and exercises the
  handoff.
- `build.sh` assembles and links the BIOS, builds the RAM test, and installs
  the generated files into the repository-local `sdcard/` directory.
- `run.sh` starts the emulator and a Minicom UART terminal connected through a
  temporary virtual serial pair.

## Build

The build expects the AgonDev toolchain: `ez80-none-elf-as` and
`ez80-none-elf-ld` in the parent AgonDev `bin/` directory, plus
`agondev-config` and `make` on `PATH`.

```sh
./build.sh
```

This creates `bin/EZ80BIOS.bin` (exactly 8192 bytes) and `bin/ramtest.bin`.
It also copies both files to `sdcard/` in this repository and writes an
`autoexec.txt` that loads and runs the RAM test. The generated card contents
are ignored by Git. Rebuilding overwrites these files in `sdcard/`.

## Run and test

The runtime script requires `fab-agon-emulator`, `socat`, `minicom`, and
`xterm` on `PATH`:

```sh
./run.sh
```

Optional emulator arguments can be passed through, for example:

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
`{RAM_ADDR_U, 0xFFFF}` and takes priority over on-chip Flash and memory chip
selects on overlap. Thus `RAM_ADDR_U = 0` maps SRAM to `0x00E000–0x00FFFF`, not
to address `0x000000`.

At BIOS entry, `CS0_LBR`/`CS0_UBR` map the 512 KiB external RAM window to pages
`0x01`–`0x08` (`0x010000`–`0x08FFFF`), immediately following the BIOS page.
This remap happens after execution has moved into the higher-priority on-chip
SRAM, so the BIOS remains executable while CS0 is reconfigured. At startup, the
BIOS copies the NUL-terminated `Memory mapped at 0x010000\r\n` string (including
its `\0`) into external SRAM at `0x010000`, then prints it from there through
`io_puts`/UART1. This checks that the newly mapped RAM is both writable and
readable.

## VSync interrupt at handoff

`src/main.c:bios_handoff()` disables CPU interrupts, clears the pending Port B
bit 1 edge, and returns PB1 to ordinary input mode before transferring control
to the BIOS. MOS leaves PB1 configured for rising-edge VSync; this BIOS uses
UART1 and does not install a VSync handler.

## UART1 interrupt driver

`EZ80BIOS.s` configures UART1 for 115200 8N1 with 16-byte FIFOs and services
its vectored interrupt (`I=0xFB`, `IVECT 0x1A`; vector table at `0xFB00`, just
before ring metadata at `0xFC00`). The ISR drains all available RX bytes into
`bios_rs_ring` and fills the TX FIFO in bursts from `bios_ts_ring`. The
256-byte rings reserve one slot to distinguish full from empty, so each holds
up to 255 bytes. RX overflow drops the byte and increments the wrapping
`bios_rs_overflow` counter.

Assembly entry points:

- `bios_uart1_tx_put`: byte in `A`; carry is set if the TX ring is full. On
  success it queues the byte and enables the TX-empty interrupt.
- `bios_uart1_rx_get`: returns a byte in `A` with carry clear, or carry set if
  the RX ring is empty. It updates RTS as space is freed.
- `io_putchar`: blocking character output; byte in `A`. It halts while the TX
  ring is full and retries after an interrupt.
- `io_getchar`: blocking character input; returns the byte in `A`. It sleeps
  while the RX ring is empty and wakes when the UART1 ISR queues data.
- `io_peek`: nonblocking RX-ring peek; returns the next byte in `A` with carry
  clear, or carry set if empty. It does not consume the byte.
- `io_nread`: blocking binary input; 24-bit `HL` points to the destination and
  24-bit `BC` is the exact byte count. It returns only after reading that many
  bytes, and restores the caller's `HL`, `BC`, `IX`, and `IY` values.
- `io_puts`: blocking NUL-terminated string output; `HL` points to the string.
- `bios_xmodem_receive`: receives a file into external RAM and returns status
  in `A` (`0` success, nonzero cancel/error). `bios_xmodem_wp` is the exclusive
  end address after the payload bytes.

## XMODEM-CRC receive

At startup the BIOS prints `XMODEM-CRC loading to 0x010000`, sends `C` to
request CRC mode, and receives Minicom's 128-byte XMODEM frames through the UART1
RX ring. PRT0 ticks every 10 ms, increments the 24-bit `bios_uptime_10ms` value,
and drains any residual hardware RX FIFO bytes into that ring. During startup,
`bios_xmodem_start` temporarily replaces the PRT0 vector. Its handler peeks at
the RX ring for SOH (or cancellation/end), resends `C` every 256 ticks
(2,560 ms), restores the saved timer vector on start, then tail-jumps to the
normal timer ISR. The SOH remains queued for the blocking receiver.

Each frame's payload and two CRC bytes are written to external SRAM, checked
with CRC-16/XMODEM (polynomial `0x1021`, initial value `0x0000`, non-reflected,
no final XOR; high CRC byte first), and the write pointer is moved back over the
CRC. Bad frames receive NAK; valid frames receive ACK, including retransmitted
duplicates. EOT is ACKed; the BIOS prints `Load complete` and `Starting`, then
jumps to `0x010000`.

Reads block on UART/timer interrupts; there are no receive timeouts. XMODEM
transmits complete 128-byte blocks and does not include the exact file length, so
any final-block padding is also present in memory. Two bytes are reserved for
the final CRC, limiting a transfer to 4095 blocks (524,160 payload bytes).

UART1 RTS is active-low. The BIOS routes PC0–PC2 to UART1 and uses hysteresis:
it deasserts RTS below 33 free RX-ring slots and reasserts it only at 133 free
slots, enough room for a full 133-byte XMODEM/CRC packet. TX does not check CTS,
so it works with UART adapters that do not provide modem-status signals.

### RX/TX function tree

```text
bios_entry
├─ print startup messages
├─ bios_xmodem_receive
│  ├─ send 'C' to request XMODEM-CRC
│  ├─ io_getchar (HALT while rs is empty)
│  ├─ receive 128-byte payload and two CRC bytes
│  ├─ CRC-16/XMODEM check ──> ACK or NAK
│  └─ EOT ──> print completion, jump to 0x010000
└─ transfer error ──> print failure, then bios_idle

bios_uart1_isr (UART1 vector 0x1A)
├─ RX causes ──> drain UART FIFO into rs, update RTS
└─ TX-empty ──> fill UART FIFO from ts

bios_xmodem_start (temporary PRT0 vector)
├─ io_peek for SOH/CAN/EOT without consuming the byte
├─ resend 'C' on the 256-tick schedule
└─ restore saved vector, then jump to bios_timer0_isr

bios_timer0_isr (PRT0 vector 0x0A; 10 ms)
├─ increment bios_uptime_10ms
└─ drain residual UART1 RX FIFO into rs
```

