;; EZ80BIOS.s — Absolute BIOS addresses are 0xE000..0xFFFF.
;; The image is loaded at 0xB7E000, then SRAM remapping makes it appear at
;; 0x00E000..0x00FFFF. The IVT at 0xFB00 sits just before the ring buffers.
;; build.sh extracts this absolute range into the 8192-byte BIOS image.
;; All non-emitting hardware/bit constants are collected in the .set block at EOF.

	.assume ADL = 1

	.global bios_entry, bios_xmodem_receive, bios_xmodem_wp, bios_uptime_10ms
	.global bios_uart1_tx_put, bios_uart1_rx_get, bios_wait
	.global io_putchar, io_getchar, io_nread, io_puts
	.global bios_rs_head, bios_rs_tail, bios_ts_head, bios_ts_tail
	.global bios_rs_overflow, bios_rs_ring, bios_ts_ring

	.section .bios,"ax",@progbits
	.org 0xE000

;; Execution begins directly at the BIOS entry point.
bios_entry:
	di
	ld sp, bios_stack_top

	;; Map the 512 KiB external RAM to pages 0x01..0x08, immediately after
	;; the BIOS page. The BIOS runs from higher-priority on-chip SRAM in page 0.
	xor a
	out0 (CS0_UBR), a
	ld a, EXTERNAL_RAM_FIRST_PAGE
	out0 (CS0_LBR), a
	ld a, EXTERNAL_RAM_LAST_PAGE
	out0 (CS0_UBR), a

	ld a, BIOS_IVT_PAGE
	ld i, a

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

	;; Copy the NUL-terminated map message to the first external RAM address.
	ld hl, bios_memory_mapped_message
	ld de, EXTERNAL_RAM_START_ADDRESS
bios_copy_memory_message:
	ld a, (hl)
	ld (de), a
	inc hl
	inc de
	or a
	jr nz, bios_copy_memory_message

	;; Start PRT0 at 10 ms (18.432 MHz / 4 / 46080).
	ld hl, BIOS_ZERO
	ld (bios_uptime_10ms), hl
	xor a
	out0 (TMR0_CTL), a
	ld a, TMR0_RELOAD_LOW_10MS
	out0 (TMR0_RR_L), a
	ld a, TMR0_RELOAD_HIGH_10MS
	out0 (TMR0_RR_H), a
	ld a, TMR0_CTL_10MS
	out0 (TMR0_CTL), a

	;; Clear stale receive/line status before enabling IRQs.
	in0 a, (UART1_LSR)
	ld a, UART1_IER_INIT          ;; RX and line-status interrupts
	out0 (UART1_IER), a
	ei

	;; Print from the newly mapped external RAM, not the BIOS image.
	ld hl, EXTERNAL_RAM_START_ADDRESS
	call io_puts
	ld hl, bios_loaded_message
	call io_puts
	ld hl, bios_xmodem_loading_message
	call io_puts
	call bios_xmodem_receive
	or a
	jr nz, bios_xmodem_failed
	ld hl, bios_xmodem_complete_message
	call io_puts
	ld hl, bios_xmodem_starting_message
	call io_puts
	jp EXTERNAL_RAM_START_ADDRESS
bios_xmodem_failed:
	ld hl, bios_xmodem_failed_message
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

bios_uart1_rx_service:
	call bios_uart1_rx_drain
	jp bios_uart1_irq_done

;; Drain all available hardware RX bytes into rs. Also called by PRT0 so a
;; sub-threshold UART FIFO is serviced on the next 10 ms tick.
bios_uart1_rx_drain:
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
	ld de, BIOS_ZERO
	ld e, b
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
	ret

;; PRT0 wakes HALT, advances uptime, and drains residual UART1 FIFO bytes.
bios_timer0_isr:
	push af
	push bc
	push de
	push hl
	push ix
	push iy
	in0 a, (TMR0_CTL)             ;; Reading CTL clears the timer IRQ flag.
	ld hl, (bios_uptime_10ms)
	inc hl
	ld (bios_uptime_10ms), hl
	call bios_uart1_rx_drain
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ei
	reti.l

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
	ld de, BIOS_ZERO
	ld e, b
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
	ld de, BIOS_ZERO
	ld e, b
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
	ld de, BIOS_ZERO
	ld e, b
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

;; Blocking UART1 character input. Sleep between RX-buffer checks; the UART1
;; interrupt wakes HALT and has already queued the received byte in rs.
io_getchar:
	di
io_getchar_retry:
	call bios_uart1_rx_get
	jr nc, io_getchar_received
	ei
	halt
	di
	jr io_getchar_retry
io_getchar_received:
	ei
	ret

;; Read exactly BC bytes from UART1 into the 24-bit address in HL.
;; Preserve the caller's HL/BC values and IX/IY used as working registers.
io_nread:
	push hl
	push bc
	push ix
	push iy
	push hl
	pop ix
	push bc
	pop iy
io_nread_loop:
	push iy
	pop hl
	ld de, BIOS_ZERO
	or a
	sbc hl, de
	jr z, io_nread_done
	call io_getchar
	ld (ix+0), a
	inc ix
	dec iy
	jr io_nread_loop
io_nread_done:
	pop iy
	pop ix
	pop bc
	pop hl
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

;; Busy-wait for about 50 ms at 18.432 MHz (~921,600 CPU cycles).
;; This uses only CPU cycles; no peripheral timer is required.
bios_wait:
	push af
	push bc
	push de
	ld d, BIOS_WAIT_OUTER
bios_wait_outer:
	ld c, 0
bios_wait_middle:
	ld b, BIOS_WAIT_INNER
bios_wait_inner:
	djnz bios_wait_inner
	dec c
	jr nz, bios_wait_middle
	dec d
	jr nz, bios_wait_outer
	pop de
	pop bc
	pop af
	ret

;; Receive XMODEM-CRC frames into external RAM. Each accepted frame stores
;; payload+CRC; after CRC validation the two-byte CRC is removed from the WP.
;; A=0 on EOT, A=1 on cancellation or insufficient external RAM.
bios_xmodem_receive:
	ld hl, EXTERNAL_RAM_START_ADDRESS
	ld (bios_xmodem_wp), hl
	ld a, 1
	ld (bios_xmodem_expected), a
	xor a
	ld (bios_xmodem_have_block), a

	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_ARM_THRESHOLD
	ld a, 0
	jr c, bios_xmodem_initial_phase_ready
	inc a
bios_xmodem_initial_phase_ready:
	ld (bios_xmodem_retry_armed), a
	ld a, XMODEM_CRC_REQUEST
	call io_putchar
bios_xmodem_wait_start:
	;; Prefer a byte already in the software ring; HALT until UART or PRT0 IRQ.
	call bios_uart1_rx_get
	jr nc, bios_xmodem_start_byte
	halt
	call bios_uart1_rx_get
	jr nc, bios_xmodem_start_byte
	jr bios_xmodem_check_retry
bios_xmodem_start_byte:
	cp XMODEM_SOH
	jr z, bios_xmodem_packet
	cp XMODEM_EOT
	jp z, bios_xmodem_complete
	cp XMODEM_CAN
	jp z, bios_xmodem_cancelled
bios_xmodem_check_retry:
	ld a, (bios_xmodem_retry_armed)
	or a
	jr z, bios_xmodem_arm_retry
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_SEND_THRESHOLD
	jr nc, bios_xmodem_wait_start
	xor a
	ld (bios_xmodem_retry_armed), a
	ld a, XMODEM_CRC_REQUEST
	call io_putchar
	jr bios_xmodem_wait_start
bios_xmodem_arm_retry:
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_ARM_THRESHOLD
	jr c, bios_xmodem_wait_start
	ld a, 1
	ld (bios_xmodem_retry_armed), a
	jr bios_xmodem_wait_start

bios_xmodem_wait_frame:
	call io_getchar
	cp XMODEM_SOH
	jr z, bios_xmodem_packet
	cp XMODEM_EOT
	jp z, bios_xmodem_complete
	cp XMODEM_CAN
	jp z, bios_xmodem_cancelled
	ld a, XMODEM_NAK
	call io_putchar
	jr bios_xmodem_wait_frame

bios_xmodem_packet:
	ld de, (bios_xmodem_wp)
	call io_getchar
	ld (bios_xmodem_block), a
	call io_getchar
	ld (bios_xmodem_complement), a

	ld a, 1
	ld (bios_xmodem_header_ok), a
	xor a
	ld (bios_xmodem_store), a
	ld a, (bios_xmodem_block)
	ld b, a
	ld a, (bios_xmodem_complement)
	xor b
	inc a
	jr nz, bios_xmodem_bad_header

	ld a, (bios_xmodem_block)
	ld b, a
	ld a, (bios_xmodem_expected)
	cp b
	jr z, bios_xmodem_expected_block
	ld a, (bios_xmodem_have_block)
	or a
	jr z, bios_xmodem_bad_header
	ld a, (bios_xmodem_expected)
	dec a
	cp b
	jr z, bios_xmodem_duplicate_block
	jr bios_xmodem_bad_header

bios_xmodem_expected_block:
	;; A 130-byte frame must fit; this boundary leaves no room for its CRC.
	ld de, (bios_xmodem_wp)
	ld hl, XMODEM_FRAME_START_NO_CRC_SPACE
	or a
	sbc hl, de
	jp z, bios_xmodem_abort
	ld a, 1
	ld (bios_xmodem_store), a
	jr bios_xmodem_read_data
bios_xmodem_duplicate_block:
	jr bios_xmodem_read_data
bios_xmodem_bad_header:
	xor a
	ld (bios_xmodem_header_ok), a

bios_xmodem_read_data:
	xor a
	ld (bios_xmodem_crc_hi), a
	ld (bios_xmodem_crc_lo), a
	ld a, XMODEM_BLOCK_SIZE
	ld (bios_xmodem_data_count), a
bios_xmodem_data_loop:
	call io_getchar
	ld (bios_xmodem_byte), a
	call bios_xmodem_crc_update
	ld a, (bios_xmodem_store)
	or a
	jr z, bios_xmodem_skip_data_store
	ld a, (bios_xmodem_byte)
	ld (de), a
	inc de
bios_xmodem_skip_data_store:
	ld a, (bios_xmodem_data_count)
	dec a
	ld (bios_xmodem_data_count), a
	jr nz, bios_xmodem_data_loop

	call io_getchar
	ld (bios_xmodem_received_crc_hi), a
	ld b, a
	ld a, (bios_xmodem_store)
	or a
	jr z, bios_xmodem_skip_crc_hi_store
	ld a, b
	ld (de), a
	inc de
bios_xmodem_skip_crc_hi_store:
	call io_getchar
	ld (bios_xmodem_received_crc_lo), a
	ld b, a
	ld a, (bios_xmodem_store)
	or a
	jr z, bios_xmodem_skip_crc_lo_store
	ld a, b
	ld (de), a
	inc de
bios_xmodem_skip_crc_lo_store:

	ld a, (bios_xmodem_header_ok)
	or a
	jp z, bios_xmodem_reject
	ld a, (bios_xmodem_crc_hi)
	ld b, a
	ld a, (bios_xmodem_received_crc_hi)
	cp b
	jp nz, bios_xmodem_reject
	ld a, (bios_xmodem_crc_lo)
	ld b, a
	ld a, (bios_xmodem_received_crc_lo)
	cp b
	jp nz, bios_xmodem_reject

	ld a, (bios_xmodem_store)
	or a
	jr z, bios_xmodem_ack
	dec de
	dec de
	ld (bios_xmodem_wp), de
	ld a, (bios_xmodem_expected)
	inc a
	ld (bios_xmodem_expected), a
	ld a, 1
	ld (bios_xmodem_have_block), a
bios_xmodem_ack:
	ld a, XMODEM_ACK
	call io_putchar
	jp bios_xmodem_wait_frame

bios_xmodem_reject:
	;; WP is unchanged, so a retransmission overwrites the rejected frame.
	ld a, XMODEM_NAK
	call io_putchar
	jp bios_xmodem_wait_frame

bios_xmodem_crc_update:
	;; A=data byte. CRC-16/XMODEM: init 0, poly 0x1021, MSB first.
	ld b, a
	ld a, (bios_xmodem_crc_hi)
	xor b
	ld (bios_xmodem_crc_hi), a
	ld c, 8
bios_xmodem_crc_bit:
	ld a, (bios_xmodem_crc_lo)
	add a, a
	ld (bios_xmodem_crc_lo), a
	ld a, (bios_xmodem_crc_hi)
	rla
	ld (bios_xmodem_crc_hi), a
	jr nc, bios_xmodem_crc_next
	ld a, (bios_xmodem_crc_lo)
	xor XMODEM_CRC_POLY_LO
	ld (bios_xmodem_crc_lo), a
	ld a, (bios_xmodem_crc_hi)
	xor XMODEM_CRC_POLY_HI
	ld (bios_xmodem_crc_hi), a
bios_xmodem_crc_next:
	dec c
	jr nz, bios_xmodem_crc_bit
	ret

bios_xmodem_complete:
	ld a, XMODEM_ACK
	call io_putchar
	xor a
	ret
bios_xmodem_cancelled:
	ld a, XMODEM_STATUS_CANCELLED
	ret
bios_xmodem_abort:
	ld a, XMODEM_CAN
	call io_putchar
	call io_putchar
	ld a, XMODEM_STATUS_ERROR
	ret

bios_loaded_message:
	.asciz "BIOS Loaded\r\n"

bios_memory_mapped_message:
	.asciz "Memory mapped at 0x010000\r\n"
bios_xmodem_loading_message:
	.asciz "XMODEM-CRC loading to 0x010000\r\n"
bios_xmodem_complete_message:
	.asciz "Load complete\r\n"
bios_xmodem_starting_message:
	.asciz "Starting\r\n"
bios_xmodem_failed_message:
	.asciz "XMODEM-CRC receive failed\r\n"

;; F92 vector entries are 16-bit ISR addresses, little-endian at I:IVECT.
;; With I=0xFB, reserved offsets 0x00..0x06 and vectors occupy 0xFB00..0xFB67,
;; immediately before the ring metadata at 0xFC00.
	.org 0xFB00
bios_unused_00:          .dw 0
bios_unused_02:          .dw 0
bios_unused_04:          .dw 0
bios_unused_06:          .dw 0
bios_flash_vector:       .dw bios_unhandled_isr ; 0x08 Flash
bios_timer0_vector:      .dw bios_timer0_isr    ; 0x0A PRT0
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

	.org 0xFC10
bios_uptime_10ms:           .ds 3, 0
bios_xmodem_wp:             .ds 3, 0
bios_xmodem_retry_armed:    .db 0
bios_xmodem_expected:       .db 0
bios_xmodem_have_block:     .db 0
bios_xmodem_block:          .db 0
bios_xmodem_complement:     .db 0
bios_xmodem_header_ok:      .db 0
bios_xmodem_store:          .db 0
bios_xmodem_data_count:     .db 0
bios_xmodem_byte:           .db 0
bios_xmodem_crc_hi:         .db 0
bios_xmodem_crc_lo:         .db 0
bios_xmodem_received_crc_hi: .db 0
bios_xmodem_received_crc_lo: .db 0

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
	.set TMR0_CTL, 0x80
	.set TMR0_RR_L, 0x81
	.set TMR0_RR_H, 0x82
	.set PC_DDR, 0x9F
	.set PC_ALT1, 0xA0
	.set PC_ALT2, 0xA1
	.set CS0_LBR, 0xA8
	.set CS0_UBR, 0xA9

	.set EXTERNAL_RAM_FIRST_PAGE, 0x01
	.set EXTERNAL_RAM_LAST_PAGE, 0x08
	.set EXTERNAL_RAM_START_ADDRESS, 0x010000
	.set XMODEM_FRAME_START_NO_CRC_SPACE, 0x08FF80
	.set XMODEM_BLOCK_SIZE, 128
	.set XMODEM_SOH, 0x01
	.set XMODEM_EOT, 0x04
	.set XMODEM_ACK, 0x06
	.set XMODEM_NAK, 0x15
	.set XMODEM_CAN, 0x18
	.set XMODEM_CRC_REQUEST, 0x43
	.set XMODEM_CRC_POLY_HI, 0x10
	.set XMODEM_CRC_POLY_LO, 0x21
	.set XMODEM_RETRY_ARM_THRESHOLD, 201
	.set XMODEM_RETRY_SEND_THRESHOLD, 200
	.set XMODEM_STATUS_CANCELLED, 1
	.set XMODEM_STATUS_ERROR, 2
	.set TMR0_RELOAD_LOW_10MS, 0x00
	.set TMR0_RELOAD_HIGH_10MS, 0xB4
	.set TMR0_CTL_10MS, 0x53
	.set BIOS_WAIT_OUTER, 4
	.set BIOS_WAIT_INNER, 0xE0

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
