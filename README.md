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

## UART1 interrupt driver

`EZ80BIOS.s` configures UART1 for 115200 8N1 with 16-byte FIFOs and services
its vectored interrupt (`I=0xFB`, `IVECT 0x1A`; vector table at `0xFB00`,
just before ring metadata at `0xFC00`). The ISR drains all available RX bytes into
`bios_rs_ring` and fills the TX FIFO in bursts from `bios_ts_ring`. The 256-byte
rings reserve one slot to distinguish full from empty, so each holds up to 255
bytes. RX overflow drops the byte and increments the wrapping
`bios_rs_overflow` counter.

The assembly entry points are:

- `bios_uart1_tx_put`: byte in `A`; carry is set if the TX ring is full. On
  success it queues the byte and enables the TX-empty interrupt.
- `bios_uart1_rx_get`: returns a byte in `A` with carry clear, or carry set if
  the RX ring is empty. It updates RTS as space is freed.
- `io_putchar`: blocking character output; byte in `A`. It halts while the TX
  ring is full and retries after an interrupt.
- `io_getchar`: blocking character input; returns the byte in `A`.
- `io_puts`: blocking NUL-terminated string output; `HL` points to the string.
  `bios_entry` uses it to print `BIOS Loaded` before entering the HALT loop.

UART1 RTS is active-low. The BIOS routes PC0–PC2 to UART1 and uses hysteresis:
it deasserts RTS below 33 free RX-ring slots and reasserts it only at 133 free
slots, enough room for a full 133-byte XMODEM/CRC packet. TX does not check CTS,
so it works with UART adapters that do not provide modem-status signals.

### RX/TX function tree

```text
bios_entry
├─ io_puts ("BIOS Loaded")
│  └─ io_putchar
│     └─ bios_uart1_tx_put (retries until queued)
└─ bios_idle (HALT; wakes on UART1 interrupt, vector 0x1A)
   └─ bios_uart1_isr
      ├─ bios_uart1_irq_next (read IIR and dispatch until no cause remains)
      │  ├─ line status (0x06) ─┐
      │  ├─ RX ready (0x04) ────┼─> bios_uart1_rx_service
      │  └─ RX timeout (0x0C) ─┘   └─ bios_uart1_rx_loop
      │                               ├─ space available: store byte in rs
      │                               ├─ ring full: drop byte, increment overflow
      │                               └─ after each byte/drain: bios_uart1_update_rts
      ├─ TX FIFO empty (0x02) ─────> bios_uart1_tx_service
      │                               └─ bios_uart1_tx_loop (up to 16 writes)
      │                                  └─ queue empty: bios_uart1_tx_disable
      └─ unexpected modem status ─> read MSR to clear cause
      └─ no pending cause ─────────> restore registers, RETI.L

io_getchar
└─ bios_uart1_rx_get (retry while empty)
   └─ read rs byte, advance tail, call bios_uart1_update_rts

bios_uart1_tx_put (low-level producer)
└─ enqueue byte, enable TIE; carry reports a full ts ring
```

**Emulator limitation:** the tested Fab Agon Emulator build does not dispatch
UART1 interrupts (its interrupt scheduler only dispatches UART0). Thus the BIOS
assembles and links, but UART1 ISR/FIFO behavior requires testing on hardware or
an emulator build with UART1 interrupt support.
