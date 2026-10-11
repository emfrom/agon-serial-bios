# memtest

## eZ80 interrupt-vector reference

The official Zilog eZ80 CPU User Manual (UM007715-0415) is available at
[Zilog's manual URL](https://www.zilog.com/docs/um0077.pdf) and was downloaded
locally to `~/opt/Downloads/um0077.pdf` for reference.

For the eZ80F92 interrupt-vector construction, see the official eZ80F92/eZ80F93
Product Specification (PS015317-0120), downloaded to
`~/opt/Downloads/PS0153.pdf`. Its “Interrupt Controller” section (printed
pages 45–47) specifies that `I` is the Interrupt Page Address Register and
the interrupting peripheral supplies its fixed 8-bit value on the internal
`IVECT[7:0]` bus. The table-entry address is `{I[7:0], IVECT[7:0]}`. The ISR's
16-bit address is stored little-endian at that address and the next byte.

In ADL mode the CPU fetches that 16-bit ISR address, sets `PC[15:0]` to it,
and runs with `PC[23:16] = 0`; it does not fetch a 24-bit ISR address. In
Z80 mode, the corresponding table entry is in the MBASE page and the execution
address is effectively `{MBASE, PC[15:0]}`. See Product Specification Table 12.

The defined eZ80F92 peripheral vector values are:

- `0x08` flash; `0x0A`–`0x14` timers 0–5
- `0x16` RTC; `0x18` UART0; `0x1A` UART1; `0x1C` I²C; `0x1E` SPI
- `0x30`–`0x3E` Port B bits 0–7
- `0x40`–`0x4E` Port C bits 0–7
- `0x50`–`0x5E` Port D bits 0–7

Other offsets in this range are reserved/unassigned by the definitions in
`ez80f92.h`. The vector table base is controlled by the CPU's `I` register;
consult the manual for the active ADL/MADL mode and device-specific details.

The Agon Platform MOS documentation's [Memory map](https://agonplatform.github.io/agon-docs/MOS/#memory-map)
section was saved locally as `~/opt/Downloads/agon-mos-memory-map.html`. It
places the Agon eZ80's 8 KiB internal RAM at `0xB7E000–0xB7FFFF` by default;
`src/main.c` loads the BIOS there before remapping RAM.

The F92 product specification (PS015317-0120, printed pages 190–192) says the
8 KiB internal SRAM occupies `{RAM_ADDR_U, 0xE000}` through
`{RAM_ADDR_U, 0xFFFF}` and takes priority over on-chip Flash and memory chip
selects on overlap. Thus `RAM_ADDR_U = 0` maps SRAM to `0x00E000–0x00FFFF`,
not to address `0x000000`.
