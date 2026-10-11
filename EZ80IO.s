;; UART1 IO API and XMODEM-CRC receiver. Included by EZ80BIOS.s in the
;; shared BIOS section so internal symbols and absolute layout stay unified.

__io_xmodem_restore_timer_vector:
	ld a, (bios_timer0_saved_vector)
	ld (bios_timer0_vector), a
	ld a, (bios_timer0_saved_vector+1)
	ld (bios_timer0_vector+1), a
	ret

;; Temporary PRT0 handler during XMODEM startup. It never returns directly
;; from the interrupt: after peeking/handshake work it restores registers and
;; tail-jumps to the regular timer ISR, which performs RETI.L.
__io_xmodem_start:
	push af
	push bc
	push de
	push hl
	push ix
	push iy
__io_xmodem_start_scan:
	call io_peek
	jr c, __io_xmodem_start_retry
	cp XMODEM_SOH
	jr z, __io_xmodem_start_detected
	cp XMODEM_EOT
	jr z, __io_xmodem_start_detected
	cp XMODEM_CAN
	jr z, __io_xmodem_start_detected
	;; Discard unrelated bytes so an old byte cannot hide the SOH behind it.
	call bios_uart1_rx_get
	jr __io_xmodem_start_scan

__io_xmodem_start_retry:
	ld a, (bios_xmodem_retry_armed)
	or a
	jr z, __io_xmodem_start_arm_retry
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_SEND_THRESHOLD
	jr nc, __io_xmodem_start_resume
	xor a
	ld (bios_xmodem_retry_armed), a
	ld a, XMODEM_CRC_REQUEST
	call bios_uart1_tx_put       ;; Nonblocking: never wait inside an ISR.
	jr __io_xmodem_start_resume
__io_xmodem_start_arm_retry:
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_ARM_THRESHOLD
	jr c, __io_xmodem_start_resume
	ld a, 1
	ld (bios_xmodem_retry_armed), a
	jr __io_xmodem_start_resume

__io_xmodem_start_detected:
	call __io_xmodem_restore_timer_vector
	ld a, 1
	ld (bios_xmodem_start_flag), a
__io_xmodem_start_resume:
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	jp __bios_timer0_isr


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
	jr z, __bios_uart1_tx_put_full
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
__bios_uart1_tx_put_full:
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
	jr z, __bios_uart1_rx_get_empty
	ld hl, bios_ringbuffer_in
	ld de, BIOS_ZERO
	ld e, b
	add hl, de
	ld a, (hl)
	push af                        ;; Preserve return byte across RTS update.
	inc b
	ld a, b
	ld (bios_rs_tail), a
	call __bios_uart1_update_rts
	pop af
	or a                           ;; Clear carry for success.
	ret
__bios_uart1_rx_get_empty:
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

;; Blocking UART1 character input; sleep between RX-buffer checks. The ISR
;; queues the byte in rs and wakes HALT. Preserve DE for callers.
io_getchar:
	di
io_getchar_retry:
	push de
	call bios_uart1_rx_get
	pop de
	jr nc, io_getchar_received
	ei
	halt
	di
	jr io_getchar_retry
io_getchar_received:
	ei
	ret

;; Nonblocking receive peek: A=next byte, carry clear; carry set if empty.
;; The byte remains in rs so a later io_getchar/io_nread receives it.
io_peek:
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	cp b
	jr z, io_peek_empty
	ld hl, bios_ringbuffer_in
	ld de, BIOS_ZERO
	ld e, b
	add hl, de
	ld a, (hl)
	or a
	ret
io_peek_empty:
	scf
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


;; Install the temporary PRT0 vector and request XMODEM-CRC until a start
;; control byte is visible in rs. The ISR discards unrelated bytes but leaves
;; SOH/CAN/EOT queued for the receiver.
__io_xmodem_wait_for_start:
	xor a
	ld (bios_xmodem_start_flag), a
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_ARM_THRESHOLD
	ld a, 0
	jr c, __io_xmodem_start_phase_ready
	inc a
__io_xmodem_start_phase_ready:
	ld (bios_xmodem_retry_armed), a

	;; Save and replace the 16-bit PRT0 vector atomically.
	di
	ld a, (bios_timer0_vector)
	ld (bios_timer0_saved_vector), a
	ld a, (bios_timer0_vector+1)
	ld (bios_timer0_saved_vector+1), a
	ld hl, __io_xmodem_start
	ld a, l
	ld (bios_timer0_vector), a
	ld a, h
	ld (bios_timer0_vector+1), a
	ei
	ld a, XMODEM_CRC_REQUEST
	call io_putchar
__io_xmodem_flag_wait:
	di
	ld a, (bios_xmodem_start_flag)
	or a
	jr nz, __io_xmodem_flag_ready
	ei
	halt
	jr __io_xmodem_flag_wait
__io_xmodem_flag_ready:
	ei
	ret

;; Receive XMODEM-CRC frames into external RAM. Each accepted frame stores
;; payload+CRC; after CRC validation the two-byte CRC is removed from the WP.
;; A=0 on EOT, nonzero on cancellation, invalid destination, or insufficient RAM.
io_xmodem_rx:
	push hl
	ld (bios_xmodem_wp), hl
	ld de, EXTERNAL_RAM_START_ADDRESS
	or a
	sbc hl, de
	jp c, __io_xmodem_rx_bad_start
	ld hl, XMODEM_LAST_SAFE_FRAME_START
	ld de, (bios_xmodem_wp)
	or a
	sbc hl, de
	jp c, __io_xmodem_rx_bad_start
	ld a, 1
	ld (bios_xmodem_expected), a
	xor a
	ld (bios_xmodem_have_block), a

	call __io_xmodem_wait_for_start
__io_xmodem_wait_first_byte:
	call io_getchar
	cp XMODEM_SOH
	jr z, __io_xmodem_packet
	cp XMODEM_EOT
	jp z, __io_xmodem_complete
	cp XMODEM_CAN
	jp z, __io_xmodem_cancelled
	ld a, XMODEM_NAK
	call io_putchar
	jr __io_xmodem_wait_first_byte

__io_xmodem_wait_frame:
	call io_getchar
	cp XMODEM_SOH
	jr z, __io_xmodem_packet
	cp XMODEM_EOT
	jp z, __io_xmodem_complete
	cp XMODEM_CAN
	jp z, __io_xmodem_cancelled
	ld a, XMODEM_NAK
	call io_putchar
	jr __io_xmodem_wait_frame

__io_xmodem_packet:
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
	jr nz, __io_xmodem_bad_header

	ld a, (bios_xmodem_block)
	ld b, a
	ld a, (bios_xmodem_expected)
	cp b
	jr z, __io_xmodem_expected_block
	ld a, (bios_xmodem_have_block)
	or a
	jr z, __io_xmodem_bad_header
	ld a, (bios_xmodem_expected)
	dec a
	cp b
	jr z, __io_xmodem_duplicate_block
	jr __io_xmodem_bad_header

__io_xmodem_expected_block:
	;; A 130-byte frame must fit in external SRAM, including both CRC bytes.
	ld de, (bios_xmodem_wp)
	ld hl, XMODEM_LAST_SAFE_FRAME_START
	or a
	sbc hl, de
	jp c, __io_xmodem_abort
	ld a, 1
	ld (bios_xmodem_store), a
	jr __io_xmodem_read_data
__io_xmodem_duplicate_block:
	jr __io_xmodem_read_data
__io_xmodem_bad_header:
	xor a
	ld (bios_xmodem_header_ok), a

__io_xmodem_read_data:
	xor a
	ld (bios_xmodem_crc_hi), a
	ld (bios_xmodem_crc_lo), a
	ld a, XMODEM_BLOCK_SIZE
	ld (bios_xmodem_data_count), a
__io_xmodem_data_loop:
	call io_getchar
	ld (bios_xmodem_byte), a
	call __io_xmodem_crc_update
	ld a, (bios_xmodem_store)
	or a
	jr z, __io_xmodem_skip_data_store
	ld a, (bios_xmodem_byte)
	ld (de), a
	inc de
__io_xmodem_skip_data_store:
	ld a, (bios_xmodem_data_count)
	dec a
	ld (bios_xmodem_data_count), a
	jr nz, __io_xmodem_data_loop

	call io_getchar
	ld (bios_xmodem_received_crc_hi), a
	ld b, a
	ld a, (bios_xmodem_store)
	or a
	jr z, __io_xmodem_skip_crc_hi_store
	ld a, b
	ld (de), a
	inc de
__io_xmodem_skip_crc_hi_store:
	call io_getchar
	ld (bios_xmodem_received_crc_lo), a
	ld b, a
	ld a, (bios_xmodem_store)
	or a
	jr z, __io_xmodem_skip_crc_lo_store
	ld a, b
	ld (de), a
	inc de
__io_xmodem_skip_crc_lo_store:

	ld a, (bios_xmodem_header_ok)
	or a
	jp z, __io_xmodem_reject
	ld a, (bios_xmodem_crc_hi)
	ld b, a
	ld a, (bios_xmodem_received_crc_hi)
	cp b
	jp nz, __io_xmodem_reject
	ld a, (bios_xmodem_crc_lo)
	ld b, a
	ld a, (bios_xmodem_received_crc_lo)
	cp b
	jp nz, __io_xmodem_reject

	ld a, (bios_xmodem_store)
	or a
	jr z, __io_xmodem_ack
	dec de
	dec de
	ld (bios_xmodem_wp), de
	ld a, (bios_xmodem_expected)
	inc a
	ld (bios_xmodem_expected), a
	ld a, 1
	ld (bios_xmodem_have_block), a
__io_xmodem_ack:
	ld a, XMODEM_ACK
	call io_putchar
	jp __io_xmodem_wait_frame

__io_xmodem_reject:
	;; WP is unchanged, so a retransmission overwrites the rejected frame.
	ld a, XMODEM_NAK
	call io_putchar
	jp __io_xmodem_wait_frame

__io_xmodem_crc_update:
	;; A=data byte. CRC-16/XMODEM: init 0, poly 0x1021, MSB first.
	ld b, a
	ld a, (bios_xmodem_crc_hi)
	xor b
	ld (bios_xmodem_crc_hi), a
	ld c, 8
__io_xmodem_crc_bit:
	ld a, (bios_xmodem_crc_lo)
	add a, a
	ld (bios_xmodem_crc_lo), a
	ld a, (bios_xmodem_crc_hi)
	rla
	ld (bios_xmodem_crc_hi), a
	jr nc, __io_xmodem_crc_next
	ld a, (bios_xmodem_crc_lo)
	xor XMODEM_CRC_POLY_LO
	ld (bios_xmodem_crc_lo), a
	ld a, (bios_xmodem_crc_hi)
	xor XMODEM_CRC_POLY_HI
	ld (bios_xmodem_crc_hi), a
__io_xmodem_crc_next:
	dec c
	jr nz, __io_xmodem_crc_bit
	ret

__io_xmodem_complete:
	ld a, XMODEM_ACK
	call io_putchar
	xor a
	jp __io_xmodem_rx_done
__io_xmodem_cancelled:
	ld a, XMODEM_STATUS_CANCELLED
	jp __io_xmodem_rx_done
__io_xmodem_abort:
	ld a, XMODEM_CAN
	call io_putchar
	call io_putchar
	ld a, XMODEM_STATUS_ERROR
	jp __io_xmodem_rx_done

;; Always put the caller's timer vector back before returning from the API.
__io_xmodem_rx_done:
	push af
	di
	call __io_xmodem_restore_timer_vector
	ei
	pop af
	pop hl
	ret
__io_xmodem_rx_bad_start:
	ld a, XMODEM_STATUS_ERROR
	pop hl
	ret

