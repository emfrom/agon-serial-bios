;; UART1 IO API and XMODEM-CRC receiver. Included by EZ80BIOS.s in the
;; shared BIOS section so internal symbols and absolute layout stay unified.

;; XMODEM startup handler registered through VECTOR_ADD. The timer ISR saves
;; AF/BC/DE/HL and IX/IY; this handler returns via POP HL / JP (HL), never RETI.
__io_xmodem_start:
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
	ld c, a
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
	ld b, TIMER0_IVECT
	ld hl, __io_xmodem_start
	ld a, BIOS_OP_VECTOR_REMOVE
	rst 0x10
	ld a, 1
	ld (bios_xmodem_start_flag), a
__io_xmodem_start_resume:
	pop hl
	jp (hl)


;; API: C=byte to enqueue. Returns carry set if ts is full; otherwise clear.
;; A successful enqueue enables TIE to start or resume transmission.
bios_uart1_tx_put:
	push af
	push bc
	push de
	push hl
	ld a, (bios_ts_head)
	ld b, a
	inc a
	ld d, a
	ld a, (bios_ts_tail)
	cp d
	jr z, __bios_uart1_tx_put_full
	ld hl, bios_ringbuffer_out
	ld l, b
	ld (hl), c
	ld a, b
	inc a
	ld (bios_ts_head), a
	in0 a, (UART1_IER)
	or UART1_IER_TIE
	out0 (UART1_IER), a
	pop hl
	pop de
	pop bc
	pop af
	or a                         ;; Clear carry for success.
	ret
__bios_uart1_tx_put_full:
	pop hl
	pop de
	pop bc
	pop af
	scf
	ret

;; API: returns next rs byte in A, carry clear; carry set if rs is empty.
;; Preserves BC, DE, and HL. Consuming a byte may reassert RTS.
bios_uart1_rx_get:
	push bc
	push de
	push hl
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	cp b
	jr z, __bios_uart1_rx_get_empty
	ld hl, bios_ringbuffer_in
	ld l, b
	ld a, (hl)
	push af                        ;; Preserve return byte across RTS update.
	inc b
	ld a, b
	ld (bios_rs_tail), a
	call __bios_uart1_update_rts
	pop af
	pop hl
	pop de
	pop bc
	or a                           ;; Clear carry for success.
	ret
__bios_uart1_rx_get_empty:
	scf
	pop hl
	pop de
	pop bc
	ret

;; Blocking UART1 character output. C is retried until the TX ring accepts it.
io_putchar:
	ld a, c
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
;; queues the byte in rs and wakes HALT. Preserves BC, DE, and HL.
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

;; Nonblocking receive peek: A=next byte, carry clear; carry set if empty.
;; Preserves BC, DE, and HL; the byte remains queued for a later read.
io_peek:
	push bc
	push de
	push hl
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	cp b
	jr z, io_peek_empty
	ld hl, bios_ringbuffer_in
	ld l, b
	ld a, (hl)
	or a
	pop hl
	pop de
	pop bc
	ret
io_peek_empty:
	scf
	pop hl
	pop de
	pop bc
	ret

;; Read exactly BC bytes from UART1 into the 24-bit address in HL.
;; IX/IY are caller-saved. IX is used as the destination pointer; BC is
;; decremented as the count and restored from the stack before returning.
io_nread:
	push af
	push bc
	push de
	push hl
	ld (bios_nread_dest), hl
	ld ix, (bios_nread_dest)
io_nread_loop:
	ld hl, BIOS_ZERO
	or a
	sbc hl, bc
	jr z, io_nread_done
	call io_getchar
	ld (ix+0), a
	inc ix
	dec bc
	jr io_nread_loop
io_nread_done:
	pop hl
	pop de
	pop bc
	pop af
	ret

;; Blocking NUL-terminated string output. HL points to the first character;
;; all caller registers are preserved.
io_puts:
	push af
	push hl
io_puts_loop:
	ld a, (hl)
	or a
	jr z, io_puts_done
	ld c, a
	call io_putchar
	inc hl
	jr io_puts_loop
io_puts_done:
	pop hl
	pop af
	ret


;; Register the startup handler through the public API, then request XMODEM-CRC.
;; The hook discards unrelated bytes but leaves SOH/CAN/EOT queued.
__io_xmodem_wait_for_start:
	push hl
	xor a
	ld (bios_xmodem_start_flag), a
	ld a, (bios_uptime_10ms)
	cp XMODEM_RETRY_ARM_THRESHOLD
	ld a, 0
	jr c, __io_xmodem_start_phase_ready
	inc a
__io_xmodem_start_phase_ready:
	ld (bios_xmodem_retry_armed), a
	ld b, TIMER0_IVECT
	ld hl, __io_xmodem_start
	ld a, BIOS_OP_VECTOR_ADD
	rst 0x10
	or a
	jr nz, __io_xmodem_register_failed
	ld a, XMODEM_CRC_REQUEST
	ld c, a
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
	pop hl
	xor a
	ret
__io_xmodem_register_failed:
	pop hl
	ret

;; Receive XMODEM-CRC frames into external RAM. BC is the maximum payload
;; capacity; only complete 128-byte payload frames are written, never the CRC.
;; A=0 on EOT, nonzero on cancellation, invalid destination, or insufficient RAM.
io_xmodem_rx:
	;; IX/IY are caller-saved by the BIOS API; do not save/restore them here.
	push bc
	push de
	push hl
	ld (bios_xmodem_wp), hl
	ld (bios_xmodem_remaining), bc
	ld de, EXTERNAL_RAM_START_ADDRESS
	or a
	sbc hl, de
	jp c, __io_xmodem_rx_bad_start
	ld hl, XMODEM_LAST_SAFE_FRAME_START
	ld de, (bios_xmodem_wp)
	or a
	sbc hl, de
	jp c, __io_xmodem_rx_bad_start
	ld hl, (bios_xmodem_remaining)
	ld de, XMODEM_BLOCK_SIZE
	or a
	sbc hl, de
	jp c, __io_xmodem_rx_bad_start
	ld a, 1
	ld (bios_xmodem_expected), a
	xor a
	ld (bios_xmodem_have_block), a

	call __io_xmodem_wait_for_start
	or a
	jp nz, __io_xmodem_rx_done
__io_xmodem_wait_first_byte:
	call io_getchar
	cp XMODEM_SOH
	jr z, __io_xmodem_packet
	cp XMODEM_EOT
	jp z, __io_xmodem_complete
	cp XMODEM_CAN
	jp z, __io_xmodem_cancelled
	ld a, XMODEM_NAK
	ld c, a
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
	ld c, a
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
	;; The whole payload frame must fit both physical RAM and caller capacity.
	ld de, (bios_xmodem_wp)
	ld hl, XMODEM_LAST_SAFE_FRAME_START
	or a
	sbc hl, de
	jp c, __io_xmodem_abort
	ld hl, (bios_xmodem_remaining)
	ld de, XMODEM_BLOCK_SIZE
	or a
	sbc hl, de
	jp c, __io_xmodem_abort
	ld de, (bios_xmodem_wp)
	ld a, 1
	ld (bios_xmodem_store), a
	jr __io_xmodem_read_data
__io_xmodem_duplicate_block:
	jr __io_xmodem_read_data
__io_xmodem_bad_header:
	xor a
	ld (bios_xmodem_header_ok), a

__io_xmodem_read_data:
	ld bc, BIOS_ZERO             ;; BC holds the 16-bit CRC during payload input.
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
	call io_getchar
	ld (bios_xmodem_received_crc_lo), a

	ld a, (bios_xmodem_header_ok)
	or a
	jp z, __io_xmodem_reject
	ld a, (bios_xmodem_received_crc_hi)
	cp b
	jp nz, __io_xmodem_reject
	ld a, (bios_xmodem_received_crc_lo)
	cp c
	jp nz, __io_xmodem_reject

	ld a, (bios_xmodem_store)
	or a
	jr z, __io_xmodem_ack
	ld (bios_xmodem_wp), de
	ld hl, (bios_xmodem_remaining)
	ld de, XMODEM_BLOCK_SIZE
	or a
	sbc hl, de
	ld (bios_xmodem_remaining), hl
	ld a, (bios_xmodem_expected)
	inc a
	ld (bios_xmodem_expected), a
	ld a, 1
	ld (bios_xmodem_have_block), a
__io_xmodem_ack:
	ld a, XMODEM_ACK
	ld c, a
	call io_putchar
	jp __io_xmodem_wait_frame

__io_xmodem_reject:
	;; WP is unchanged, so a retransmission overwrites the rejected frame.
	ld a, XMODEM_NAK
	ld c, a
	call io_putchar
	jp __io_xmodem_wait_frame

__io_xmodem_crc_update:
	;; A=data byte; BC=CRC high:low. Keep CRC in registers during the bit loop.
	;; CRC-16/XMODEM uses init 0, poly 0x1021, MSB first, no final XOR.
	xor b
	ld b, a
	ld l, 8
__io_xmodem_crc_bit:
	sla c
	rl b
	jr nc, __io_xmodem_crc_next
	ld a, c
	xor XMODEM_CRC_POLY_LO
	ld c, a
	ld a, b
	xor XMODEM_CRC_POLY_HI
	ld b, a
__io_xmodem_crc_next:
	dec l
	jr nz, __io_xmodem_crc_bit
	ret

__io_xmodem_complete:
	ld a, XMODEM_ACK
	ld c, a
	call io_putchar
	xor a
	jp __io_xmodem_rx_done
__io_xmodem_cancelled:
	ld a, XMODEM_STATUS_CANCELLED
	jp __io_xmodem_rx_done
__io_xmodem_abort:
	ld a, XMODEM_CAN
	ld c, a
	call io_putchar
	call io_putchar
	ld a, XMODEM_STATUS_ERROR
	jp __io_xmodem_rx_done

;; Remove the handshake handler on every exit, preserving the result.
__io_xmodem_rx_done:
	push af
	ld b, TIMER0_IVECT
	ld hl, __io_xmodem_start
	ld a, BIOS_OP_VECTOR_REMOVE
	rst 0x10
	pop af
	pop hl
	pop de
	pop bc
	ret
__io_xmodem_rx_bad_start:
	ld a, XMODEM_STATUS_ERROR
	jp __io_xmodem_rx_done

