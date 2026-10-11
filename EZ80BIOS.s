;; EZ80BIOS.s — Absolute BIOS addresses are 0xE000..0xFFFF.
;; The image is loaded at 0xB7E000, then SRAM remapping makes it appear at
;; 0x00E000..0x00FFFF. The IVT at 0xFB00 sits just before the ring buffers.
;; build.sh extracts this absolute range into the 8192-byte BIOS image.
;; All non-emitting hardware/bit constants are collected in the .set block at EOF.

	.assume ADL = 1

	.global bios_entry
	.global bios_uart1_tx_put, bios_uart1_rx_get
	.global io_putchar, io_getchar, io_puts
	.global bios_rs_head, bios_rs_tail, bios_ts_head, bios_ts_tail
	.global bios_rs_overflow, bios_rs_ring, bios_ts_ring

	.section .bios,"ax",@progbits
	.org 0xE000

;; Execution begins directly at the BIOS entry point.
bios_entry:
	di
	ld sp, bios_stack_top
	ld a, BIOS_IVT_PAGE
	ld i, a

	;; MOS leaves PB1 in rising-edge interrupt mode, and the emulator pulses
	;; it for VSync. This BIOS does not use VSync; clear any pending edge and
	;; return PB1 to ordinary input mode before enabling CPU interrupts.
	in0 a, (PB_DR)
	or GPIO_B1_MASK
	out0 (PB_DR), a
	in0 a, (PB_ALT1)
	ld b, a
	ld a, GPIO_B1_MASK
	cpl
	and b
	out0 (PB_ALT1), a
	in0 a, (PB_ALT2)
	ld b, a
	ld a, GPIO_B1_MASK
	cpl
	and b
	out0 (PB_ALT2), a

	;; Power UART1 before configuring it.
	in0 a, (CLK_PPD1)
	ld b, a
	ld a, UART1_OFF
	cpl
	and b
	out0 (CLK_PPD1), a
	xor a
	out0 (UART1_IER), a

	;; Route PC0/PC1 (UART1 TX/RX) and PC2 (RTS).
	;; GPIO mode 7 is ALT2=1, ALT1=0, DDR=1.
	in0 a, (PC_DDR)
	or UART1_GPIO_PINS
	out0 (PC_DDR), a
	in0 a, (PC_ALT1)
	ld b, a
	ld a, UART1_GPIO_PINS
	cpl
	and b
	out0 (PC_ALT1), a
	in0 a, (PC_ALT2)
	or UART1_GPIO_PINS
	out0 (PC_ALT2), a

	;; 115200 baud from the Agon's 18.432 MHz system clock: divisor 10.
	;; DLAB=1, then 8 data bits, no parity, one stop bit.
	ld a, UART1_LCTL_DLAB | UART1_LCTL_8N1
	out0 (UART1_LCTL), a
	ld a, UART1_BRG_DIVISOR_115200
	out0 (UART1_BRG_L), a
	xor a
	out0 (UART1_BRG_H), a
	ld a, UART1_LCTL_8N1
	out0 (UART1_LCTL), a

	;; Enable both 16-byte FIFOs; clear them and interrupt RX at 14 bytes.
	ld a, UART1_FCTL_FIFO_INIT
	out0 (UART1_FCTL), a

	;; Empty the software rings and overflow counter.
	xor a
	ld (bios_rs_head), a
	ld (bios_rs_tail), a
	ld (bios_ts_head), a
	ld (bios_ts_tail), a
	ld (bios_rs_overflow), a

	;; Use only RTS from MCTL; RTS is active-low at the pin.
	ld a, UART1_MCTL_RTS          ;; DTR stays off.
	out0 (UART1_MCTL), a

	;; Clear stale receive/line status before enabling IRQs.
	in0 a, (UART1_LSR)
	ld a, UART1_IER_INIT          ;; RX and line-status interrupts
	out0 (UART1_IER), a
	ei

	ld hl, bios_loaded_message
	call io_puts

bios_idle:
	halt
	jr bios_idle

bios_unhandled_isr:
	reti.l

;; UART1 interrupt service routine. RX is drained completely into rs; TX is
;; filled in 16-byte FIFO bursts from ts. Preserve the interrupted context.
bios_uart1_isr:
	push af
	push bc
	push de
	push hl
	push ix
	push iy

;; Handle one IIR cause per entry. Any remaining enabled cause retriggers
;; after RETI; do not spin rereading IIR inside the ISR.
bios_uart1_irq_next:
	in0 a, (UART1_IIR)
	ld b, a
	and UART1_IIR_INTBIT
	jp nz, bios_uart1_irq_done
	ld a, b
	and UART1_IIR_INSTS_MASK
	cp UART1_IIR_LINE_STATUS     ;; Receiver line-status error
	jr z, bios_uart1_irq_line_status
	cp UART1_IIR_RX_DATA_READY
	jr z, bios_uart1_rx_service
	cp UART1_IIR_RX_TIMEOUT
	jr z, bios_uart1_rx_service
	cp UART1_IIR_TX_EMPTY         ;; Transmit FIFO empty
	jr z, bios_uart1_tx_service

	;; Modem-status interrupts are disabled; clear any unexpected cause.
	in0 a, (UART1_MSR)
	jp bios_uart1_irq_done

bios_uart1_irq_line_status:
	in0 a, (UART1_LSR)            ;; Reading LSR clears line-status causes.

;; Drain all currently available bytes, not just the FIFO's first byte.
bios_uart1_rx_service:
bios_uart1_rx_loop:
	in0 a, (UART1_LSR)
	and UART1_LSR_DR              ;; Receiver data ready?
	jr z, bios_uart1_rx_done
	in0 a, (UART1_RBR)
	ld c, a                       ;; Preserve byte while checking ring space.
	ld a, (bios_rs_head)
	ld b, a                       ;; B = current head
	inc a
	ld d, a                       ;; D = next head
	ld a, (bios_rs_tail)
	cp d
	jr z, bios_uart1_rx_full      ;; One slot is reserved to distinguish full.

	ld hl, bios_ringbuffer_in
	ld e, b
	ld d, BIOS_ZERO
	add hl, de
	ld (hl), c
	ld a, b
	inc a
	ld (bios_rs_head), a
	call bios_uart1_update_rts
	jr bios_uart1_rx_loop

bios_uart1_rx_full:
	ld a, (bios_rs_overflow)
	inc a
	ld (bios_rs_overflow), a
	call bios_uart1_update_rts
	jr bios_uart1_rx_loop

bios_uart1_rx_done:
	call bios_uart1_update_rts
	jp bios_uart1_irq_done

;; A THRE interrupt means the hardware TX FIFO is empty. Fill up to all 16
;; slots. Leave TIE enabled only when software data remains queued.
bios_uart1_tx_service:
	ld c, UART1_TX_FIFO_CAPACITY
bios_uart1_tx_loop:
	ld a, (bios_ts_tail)
	ld b, a
	ld a, (bios_ts_head)
	cp b
	jr z, bios_uart1_tx_disable

	ld hl, bios_ringbuffer_out
	ld e, b
	ld d, BIOS_ZERO
	add hl, de
	ld a, (hl)
	out0 (UART1_THR), a
	inc b
	ld a, b
	ld (bios_ts_tail), a
	dec c
	jr nz, bios_uart1_tx_loop

	;; The FIFO is full. If that also emptied ts, stop empty-FIFO IRQs.
	ld a, (bios_ts_head)
	ld b, a
	ld a, (bios_ts_tail)
	cp b
	jr z, bios_uart1_tx_disable
	call bios_uart1_tie_enable
	jp bios_uart1_irq_done

bios_uart1_tx_disable:
	call bios_uart1_tie_disable
	jp bios_uart1_irq_done

bios_uart1_tie_enable:
	in0 a, (UART1_IER)
	or UART1_IER_TIE              ;; Keep refilling while software TX data remains.
	out0 (UART1_IER), a
	ret

bios_uart1_tie_disable:
	in0 a, (UART1_IER)
	and UART1_IER_TIE_CLEAR       ;; Preserve RX and line-status enables.
	out0 (UART1_IER), a
	ret

bios_uart1_irq_done:
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ei                             ;; Enable after the following RETI.L.
	reti.l

;; Hysteresis: deassert RTS below 33 free slots; reassert only at 133 free
;; slots (one complete XMODEM/CRC packet). Keep the current state in between.
bios_uart1_update_rts:
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	ld c, a
	ld a, b
	sub c
	dec a                         ;; free = tail - head - 1 (modulo 256)
	cp BIOS_RS_RTS_LOW_WATERMARK
	jr c, bios_uart1_rts_deassert
	cp BIOS_RS_RTS_REASSERT_WATERMARK
	ret c                         ;; Preserve current RTS in the hysteresis band.
	ld a, UART1_MCTL_RTS          ;; MCTL RTS=1 drives active-low RTS asserted.
	out0 (UART1_MCTL), a
	ret
bios_uart1_rts_deassert:
	xor a                         ;; MCTL RTS=0 deasserts active-low RTS.
	out0 (UART1_MCTL), a
	ret

;; API: A=byte to enqueue. Returns carry set if ts is full; otherwise clear.
;; A successful enqueue enables TIE to start or resume transmission.
bios_uart1_tx_put:
	ld c, a
	ld a, (bios_ts_head)
	ld b, a
	inc a
	ld d, a
	ld a, (bios_ts_tail)
	cp d
	jr z, bios_uart1_tx_put_full
	ld hl, bios_ringbuffer_out
	ld e, b
	ld d, BIOS_ZERO
	add hl, de
	ld (hl), c
	ld a, b
	inc a
	ld (bios_ts_head), a
	in0 a, (UART1_IER)
	or UART1_IER_TIE
	out0 (UART1_IER), a
	or a                         ;; Clear carry for success.
	ret
bios_uart1_tx_put_full:
	scf
	ret

;; API: returns next rs byte in A, carry clear; carry set if rs is empty.
;; The ISR owns rs_head and this reader owns rs_tail, so byte-sized indices
;; need no interrupt masking. Consuming a byte may reassert RTS.
bios_uart1_rx_get:
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	cp b
	jr z, bios_uart1_rx_get_empty
	ld hl, bios_ringbuffer_in
	ld e, b
	ld d, BIOS_ZERO
	add hl, de
	ld a, (hl)
	push af                        ;; Preserve return byte across RTS update.
	inc b
	ld a, b
	ld (bios_rs_tail), a
	call bios_uart1_update_rts
	pop af
	or a                           ;; Clear carry for success.
	ret
bios_uart1_rx_get_empty:
	scf
	ret

;; Blocking UART1 character output. A is retried until the TX ring accepts it.
io_putchar:
	push af
io_putchar_retry:
	pop af
	push af
	call bios_uart1_tx_put
	jr nc, io_putchar_queued
	halt                           ;; TX-empty interrupt wakes after the ISR frees space.
	jr io_putchar_retry
io_putchar_queued:
	pop af
	ret

;; Blocking UART1 character input. Returns the byte in A.
io_getchar:
	call bios_uart1_rx_get
	jr c, io_getchar
	ret

;; Blocking NUL-terminated string output. HL points to the first character.
io_puts:
	ld a, (hl)
	or a
	ret z
	push hl
	call io_putchar
	pop hl
	inc hl
	jr io_puts

bios_loaded_message:
	.asciz "BIOS Loaded"

;; F92 vector entries are 16-bit ISR addresses, little-endian at I:IVECT.
;; With I=0xFB, reserved offsets 0x00..0x06 and vectors occupy 0xFB00..0xFB67,
;; immediately before the ring metadata at 0xFC00.
	.org 0xFB00
bios_unused_00:          .dw 0
bios_unused_02:          .dw 0
bios_unused_04:          .dw 0
bios_unused_06:          .dw 0
bios_flash_vector:       .dw bios_unhandled_isr ; 0x08 Flash
bios_timer0_vector:      .dw bios_unhandled_isr ; 0x0A PRT0
bios_timer1_vector:      .dw bios_unhandled_isr ; 0x0C PRT1
bios_timer2_vector:      .dw bios_unhandled_isr ; 0x0E PRT2
bios_timer3_vector:      .dw bios_unhandled_isr ; 0x10 PRT3
bios_timer4_vector:      .dw bios_unhandled_isr ; 0x12 PRT4
bios_timer5_vector:      .dw bios_unhandled_isr ; 0x14 PRT5
bios_rtc_vector:         .dw bios_unhandled_isr ; 0x16 RTC
bios_uart0_vector:       .dw bios_unhandled_isr ; 0x18 UART0
bios_uart1_vector:       .dw bios_uart1_isr    ; 0x1A UART1
bios_i2c_vector:         .dw bios_unhandled_isr ; 0x1C I2C
bios_spi_vector:         .dw bios_unhandled_isr ; 0x1E SPI
bios_unused_20:          .dw 0                 ; 0x20 unused
bios_unused_22:          .dw 0                 ; 0x22 unused
bios_unused_24:          .dw 0                 ; 0x24 unused
bios_unused_26:          .dw 0                 ; 0x26 unused
bios_unused_28:          .dw 0                 ; 0x28 unused
bios_unused_2a:          .dw 0                 ; 0x2A unused
bios_unused_2c:          .dw 0                 ; 0x2C unused
bios_unused_2e:          .dw 0                 ; 0x2E unused
bios_portb0_vector:      .dw bios_unhandled_isr ; 0x30 Port B0
bios_portb1_vector:      .dw bios_unhandled_isr ; 0x32 Port B1
bios_portb2_vector:      .dw bios_unhandled_isr ; 0x34 Port B2
bios_portb3_vector:      .dw bios_unhandled_isr ; 0x36 Port B3
bios_portb4_vector:      .dw bios_unhandled_isr ; 0x38 Port B4
bios_portb5_vector:      .dw bios_unhandled_isr ; 0x3A Port B5
bios_portb6_vector:      .dw bios_unhandled_isr ; 0x3C Port B6
bios_portb7_vector:      .dw bios_unhandled_isr ; 0x3E Port B7
bios_portc0_vector:      .dw bios_unhandled_isr ; 0x40 Port C0
bios_portc1_vector:      .dw bios_unhandled_isr ; 0x42 Port C1
bios_portc2_vector:      .dw bios_unhandled_isr ; 0x44 Port C2
bios_portc3_vector:      .dw bios_unhandled_isr ; 0x46 Port C3
bios_portc4_vector:      .dw bios_unhandled_isr ; 0x48 Port C4
bios_portc5_vector:      .dw bios_unhandled_isr ; 0x4A Port C5
bios_portc6_vector:      .dw bios_unhandled_isr ; 0x4C Port C6
bios_portc7_vector:      .dw bios_unhandled_isr ; 0x4E Port C7
bios_portd0_vector:      .dw bios_unhandled_isr ; 0x50 Port D0
bios_portd1_vector:      .dw bios_unhandled_isr ; 0x52 Port D1
bios_portd2_vector:      .dw bios_unhandled_isr ; 0x54 Port D2
bios_portd3_vector:      .dw bios_unhandled_isr ; 0x56 Port D3
bios_portd4_vector:      .dw bios_unhandled_isr ; 0x58 Port D4
bios_portd5_vector:      .dw bios_unhandled_isr ; 0x5A Port D5
bios_portd6_vector:      .dw bios_unhandled_isr ; 0x5C Port D6
bios_portd7_vector:      .dw bios_unhandled_isr ; 0x5E Port D7
bios_unused_60:          .dw 0                 ; 0x60 unused
bios_unused_62:          .dw 0                 ; 0x62 unused
bios_unused_64:          .dw 0                 ; 0x64 unused
bios_unused_66:          .dw 0                 ; 0x66 unused

	.org 0xFC00
bios_rs_head:     .db 0
bios_rs_tail:     .db 0
bios_ts_head:     .db 0
bios_ts_tail:     .db 0
bios_rs_overflow: .db 0

	.org 0xFD00
bios_rs_ring:
bios_ringbuffer_in:
	.ds 256, 0

	.org 0xFE00
bios_ts_ring:
bios_ringbuffer_out:
	.ds 256, 0

	.org 0xFF00
bios_stack:
	.ds 256, 0

;; Non-emitting constants: register names follow ez80f92.h/ez80f92.inc and
;; the eZ80F92 product specification. Keep all hardware values here.
	.set UART1_RBR, 0xD0
	.set UART1_THR, 0xD0
	.set UART1_BRG_L, 0xD0
	.set UART1_IER, 0xD1
	.set UART1_BRG_H, 0xD1
	.set UART1_IIR, 0xD2
	.set UART1_FCTL, 0xD2
	.set UART1_LCTL, 0xD3
	.set UART1_MCTL, 0xD4
	.set UART1_LSR, 0xD5
	.set UART1_MSR, 0xD6
	.set CLK_PPD1, 0xDB
	.set PB_DR, 0x9A
	.set PB_ALT1, 0x9C
	.set PB_ALT2, 0x9D
	.set PC_DDR, 0x9F
	.set PC_ALT1, 0xA0
	.set PC_ALT2, 0xA1

	.set UART1_LSR_DR, 0x01
	.set UART1_IER_RIE, 0x01
	.set UART1_IER_TIE, 0x02
	.set UART1_IER_LSIE, 0x04
	.set UART1_IER_TIE_CLEAR, 0xFD
	.set UART1_IIR_INTBIT, 0x01
	.set UART1_IIR_INSTS_MASK, 0x0E
	.set UART1_IIR_TX_EMPTY, 0x02
	.set UART1_IIR_RX_DATA_READY, 0x04
	.set UART1_IIR_LINE_STATUS, 0x06
	.set UART1_IIR_RX_TIMEOUT, 0x0C
	.set UART1_FCTL_FIFOEN, 0x01
	.set UART1_FCTL_CLRRXF, 0x02
	.set UART1_FCTL_CLRTXF, 0x04
	.set UART1_FCTL_TRIG_14, 0xC0
	.set UART1_LCTL_8N1, 0x03
	.set UART1_LCTL_DLAB, 0x80
	.set UART1_MCTL_RTS, 0x02
	.set UART1_OFF, 0x02
	.set PORTPIN_ZERO, 0x01
	.set PORTPIN_ONE, 0x02
	.set PORTPIN_TWO, 0x04
	.set GPIO_B1_MASK, PORTPIN_ONE
	.set UART1_GPIO_PINS, PORTPIN_ZERO | PORTPIN_ONE | PORTPIN_TWO
	.set BIOS_ZERO, 0
	.set UART1_BRG_DIVISOR_115200, 10
	.set UART1_TX_FIFO_CAPACITY, 16
	.set UART1_FCTL_FIFO_INIT, UART1_FCTL_FIFOEN | UART1_FCTL_CLRRXF | UART1_FCTL_CLRTXF | UART1_FCTL_TRIG_14
	.set UART1_IER_INIT, UART1_IER_RIE | UART1_IER_LSIE
	.set BIOS_IVT_PAGE, 0xFB
	.set BIOS_RS_RTS_LOW_WATERMARK, 33
	.set BIOS_RS_RTS_REASSERT_WATERMARK, 133
	.set bios_stack_top, 0x010000
