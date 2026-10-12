# BIOS RST 10h API

The BIOS exposes its client interface through software interrupt `RST.LIS 10h`.
This is a DOS/BIOS-style operation dispatcher: load the operation number into
`A`, prepare any arguments in the listed registers, then execute the RST. The
RST return address remains on the stack and returning operations return to the
instruction following the RST.

This API is **not** the IBM PC video BIOS `INT 10h` interface. These are the
operations implemented by this Agon BIOS dispatcher.

## Calling convention

- `A` selects the operation and is always clobbered. Some operations return a
  result in `A`.
- `BC` carries byte counts where applicable; `C` carries a single-byte
  character argument for the character-output operations.
- `HL` and `DE` carry addresses. `HL` holds the function pointer for
  `CALL_HL`.
- `IX` and `IY` are caller-saved: the BIOS may modify them on any operation.
  Callers that need their values must preserve them before invoking the BIOS.
- Unless an operation says otherwise, preserve no assumptions about registers
  or flags not explicitly described below.
- Blocking operations may sleep while waiting for UART interrupts. The caller
  must use the BIOS's configured memory map and provide valid readable or
  writable addresses.

The numeric operation IDs are defined in the BIOS dispatcher and listed below
for client code.

## Operation list

| ID | Operation | Arguments | Result |
| ---: | --- | --- | --- |
| `00h` | `PUTCHAR` | `C` = byte | Blocking UART1 output |
| `01h` | `GETCHAR` | — | Blocking UART1 input; byte in `A` |
| `02h` | `PEEK` | — | Nonblocking RX-ring peek; byte in `A`, carry set if empty |
| `03h` | `NREAD` | `HL` = destination, `BC` = byte count | Blocking exact-length binary input |
| `04h` | `PUTS` | `HL` = NUL-terminated string | Blocking UART1 string output |
| `05h` | `XMODEM_RX` | `HL` = destination | XMODEM-CRC receive; status in `A` |
| `06h` | `TX_PUT` | `C` = byte | Nonblocking TX enqueue; carry set if full |
| `07h` | `RX_GET` | — | Nonblocking RX dequeue; byte in `A`, carry set if empty |
| `08h` | `WAIT` | — | Busy-wait for approximately 50 ms |
| `09h` | `HALT` | — | Enter interrupt-enabled idle loop; does not return |
| `0Ah` | `CALL_HL` | `HL` = function pointer | Tail-call the function through the RST return frame |

Unknown operation values return with `A = 0FFh`.

## Operations

### `00h` — `PUTCHAR`

Pass the byte in `C`. Sends it on UART1, blocking until the TX ring has space.
On return, `A` contains the byte that was sent. The TX ring and UART interrupt
service perform the actual transmission.

### `01h` — `GETCHAR`

Waits until a byte is available in the UART1 receive ring, then returns it in
`A`. The byte is consumed. This operation may enable interrupts and sleep
between ring checks.

### `02h` — `PEEK`

Checks the UART1 receive ring without consuming a byte. If nonempty, returns
the next byte in `A` with carry clear. If empty, carry is set; `A` is
unspecified in that case.

### `03h` — `NREAD`

Pass the destination address in 24-bit `HL` and the exact number of bytes in
`BC`. Blocks until all requested bytes have been received and written to
memory. A zero count performs no reads. `AF`, `BC`, `DE`, and `HL` are
preserved. `IX` is used as the destination pointer and is clobbered; as always,
callers are responsible for preserving `IX` and `IY` if needed.

### `04h` — `PUTS`

Pass a readable NUL-terminated string address in 24-bit `HL`. Sends bytes on
UART1 up to, but not including, the NUL terminator, blocking as needed. The
string must remain readable for the duration of the call.

### `05h` — `XMODEM_RX`

Pass a destination in `HL` within external SRAM (`0x010000` through
`0x07FF7E`). Receives 128-byte XMODEM-CRC frames. Returns `A = 0` on successful
EOT, `A = 1` on cancellation, and `A = 2` on an invalid destination or receive
error. The caller's `BC`, `DE`, and `HL` are preserved. The BIOS does not preserve `IX` or `IY`;
callers must save them if needed. The receive operation temporarily uses PRT0 for handshake and FIFO service and restores the
previous PRT0 vector before returning. CRC is CRC-16/XMODEM (polynomial
`0x1021`, initial value `0x0000`, MSB first, no final XOR).

The transfer stores complete 128-byte blocks, including any final-block
padding. The exclusive end pointer and other receiver state are BIOS-internal,
not part of this public interface.

### `06h` — `TX_PUT`

Pass one byte in `C`. Attempts to enqueue it in the UART1 TX ring and returns
immediately. Carry clear means queued; carry set means the ring was full and
the byte was not queued.

### `07h` — `RX_GET`

Attempts to dequeue one byte from the UART1 RX ring without waiting. On
success, returns the consumed byte in `A` with carry clear. If the ring is
empty, carry is set and `A` is unspecified.

### `08h` — `WAIT`

Performs a CPU busy-wait of approximately 50 ms at the BIOS's nominal system
clock. It does not depend on the peripheral timer.

### `09h` — `HALT`

Enables interrupts and enters the BIOS idle loop. It does not return through
the RST frame; an interrupt wakes the CPU, after which the BIOS resumes its
idle loop.

### `0Ah` — `CALL_HL`

Tail-calls the 24-bit function address in `HL`. The function executes with the
RST caller's return frame on the stack; a normal return from the target returns
to the instruction after `RST.LIS 10h`. The function pointer must refer to
executable memory and the target must follow the caller's expected eZ80 calling
convention. Other arguments, such as `BC` or `DE`, are available to the target;
`HL` is occupied by the function pointer at dispatch time.
