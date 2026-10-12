# Agon Serial BIOS

A UART1 BIOS for the Agon eZ80. It provides an interrupt-driven serial API,
XMODEM-CRC uploads, and a small WASD terminal example.

## Build

The build uses the AgonDev toolchain (`ez80-none-elf-as`, `ez80-none-elf-ld`,
`agondev-config`, and `make`). From the project root, run:

```sh
./build.sh
```

This builds the 8 KiB BIOS image, the BIOS loader, examples, and test programs.
It also prepares `sdcard/` for the emulator. Generated files in `bin/`, `obj/`,
and `sdcard/` are ignored by Git.

## Run

Install our [patched Fab Agon Emulator](https://github.com/emfrom/fab-agon-emulator)
from its [releases page](https://github.com/emfrom/fab-agon-emulator/releases),
plus Minicom, Python 3, `timeout`, and one supported terminal (`st`, `ghosty`,
`ghostty`, `alacritty`, or `xterm`). The launcher checks the emulator's
`--version` once with a three-second timeout; its version must include
`empatch-` followed by at least six hexadecimal digits.

```sh
./run.sh
./run.sh --xmodem bin/helloserial.bin
./run.sh --xmodem bin/xwasd.bin
```

XMODEM uploads require `sx` from `lrzsz`. The launcher connects UART1 to
Minicom, sets Minicom's upload directory to `bin/`, and uses a small bridge to
answer the terminal-size query. Emulator options can be passed through, for
example `./run.sh --debugger`.

Firmware defaults to `$XDG_DATA_HOME/fab-agon-emulator`, or
`~/.local/share/fab-agon-emulator` when `XDG_DATA_HOME` is unset. Set
`FAB_AGON_FIRMWARE_DIR` to use another directory, or pass `--vdp` and `--mos`
directly. Set `FAB_AGON_EMULATOR` to choose a specific emulator binary.

## Memory layout

The BIOS image is loaded at `0xB7E000` and starts at `0x00E000` after the memory
map is changed. External SRAM covers `0x000000–0x07FFFF`; the BIOS reserves the
first 64 KiB, and programs and uploads start at `0x010000`.

- `0x000000–0x00003F`: the eight software RST vectors, copied from the BIOS
  template during startup.
- `0xE000–0xE067`: the active peripheral IVT. It overlays the hard-start code
  after the BIOS has jumped to its persistent initializer.
- `0xE068`: runtime state; the stack is at `0xE100`, RX/TX rings at `0xE200` and
  `0xE300`, and vector templates at `0xE400`.

`test/testbios_layout.py` checks the fixed addresses and image size.

## BIOS API and XMODEM

Programs call BIOS services through `RST 10h`; the operation IDs and register
contracts are documented in [`bios/BIOS_API.md`](bios/BIOS_API.md). The BIOS
supports serial input/output, bounded XMODEM-CRC receive, and PRT0 interrupt
extensions.

At startup, the BIOS waits for an XMODEM-CRC upload to `0x010000`. Transfers
use 128-byte frames, so the final frame may include padding. After a successful
upload, press `R` to run the program. The receiver checks both the caller's
capacity and physical SRAM limits before accepting each frame.

## Tests

Run from the project root:

```sh
python3 test/testbios_layout.py
python3 test/test_uart_bridge.py
python3 test/test_run_script.py
python3 test/testbios.py
python3 test/testxwasd.py
```

The BIOS test requires `sx` and the patched emulator. The tests cover the fixed
memory map, the UART/terminal bridge and launcher, the RST 10h API, XMODEM, and
the WASD example's terminal sizing, movement, edge handling, and restart keys.
