;; Loadable RST 10h BIOS API test suite. See BIOS_API.md.
	.assume ADL = 1
	.global testbios

	.set BIOS_OP_PUTCHAR, 0x00
	.set BIOS_OP_GETCHAR, 0x01
	.set BIOS_OP_PEEK, 0x02
	.set BIOS_OP_NREAD, 0x03
	.set BIOS_OP_PUTS, 0x04
	.set BIOS_OP_XMODEM_RX, 0x05
	.set BIOS_OP_TX_PUT, 0x06
	.set BIOS_OP_RX_GET, 0x07
	.set BIOS_OP_WAIT, 0x08
	.set BIOS_OP_HALT, 0x09
	.set BIOS_OP_CALL_HL, 0x0A

	.section .testbios,"ax",@progbits

testbios:
	ld hl, msg_start
	call test_puts

;; PUTCHAR: exercise ordinary, NUL, and trailing bytes.
	ld hl, msg_putchar_prefix
	call test_puts
	ld c, 'A'
	ld a, BIOS_OP_PUTCHAR
	rst 0x10
	ld c, 0
	ld a, BIOS_OP_PUTCHAR
	rst 0x10
	ld c, 'Z'
	ld a, BIOS_OP_PUTCHAR
	rst 0x10
	ld hl, msg_crlf
	call test_puts

;; PUTS: nonempty, empty, and a second nonempty string.
	ld hl, msg_puts_prefix
	call test_puts
	ld hl, msg_puts_one
	ld a, BIOS_OP_PUTS
	rst 0x10
	ld hl, msg_empty
	ld a, BIOS_OP_PUTS
	rst 0x10
	ld hl, msg_puts_two
	ld a, BIOS_OP_PUTS
	rst 0x10

;; WAIT twice; the host harness checks elapsed time between markers.
	ld hl, msg_wait_begin
	call test_puts
	ld a, BIOS_OP_WAIT
	rst 0x10
	ld a, BIOS_OP_WAIT
	rst 0x10
	ld hl, msg_wait_end
	call test_puts

;; CALL_HL returns through the RST frame to the caller.
	ld hl, test_callback
	ld a, BIOS_OP_CALL_HL
	rst 0x10
	cp 0x5A
	jp nz, test_fail
	ld hl, msg_call_hl_pass
	call test_puts
	ld hl, test_callback_second
	ld a, BIOS_OP_CALL_HL
	rst 0x10
	cp 0xA5
	jp nz, test_fail
	ld hl, msg_call_hl_second_pass
	call test_puts

;; Unknown IDs report 0xFF with carry clear.
	ld a, 0x7F
	rst 0x10
	jp c, test_fail
	cp 0xFF
	jp nz, test_fail
	ld hl, msg_badop_pass
	call test_puts

;; Empty-ring behavior and zero-length NREAD must not consume input.
	ld a, BIOS_OP_PEEK
	rst 0x10
	jp nc, test_fail
	ld a, BIOS_OP_RX_GET
	rst 0x10
	jp nc, test_fail
	ld hl, test_nread_one
	ld bc, 0
	ld a, BIOS_OP_NREAD
	rst 0x10
	ld a, BIOS_OP_PEEK
	rst 0x10
	jp nc, test_fail
	ld hl, msg_empty_pass
	call test_puts

;; GETCHAR blocks until the host supplies G.
	ld hl, msg_getchar_ready
	call test_puts
	ld a, BIOS_OP_GETCHAR
	rst 0x10
	cp 'G'
	jp nz, test_fail
	ld hl, msg_getchar_pass
	call test_puts
	ld hl, msg_getchar_second_ready
	call test_puts
	ld a, BIOS_OP_GETCHAR
	rst 0x10
	cp 'H'
	jp nz, test_fail
	ld hl, msg_getchar_second_pass
	call test_puts

;; PEEK leaves P queued; RX_GET consumes it. Empty is checked afterward.
	ld hl, msg_peek_ready
	call test_puts
test_peek_wait:
	ld a, BIOS_OP_PEEK
	rst 0x10
	jr c, test_peek_wait
	cp 'P'
	jp nz, test_fail
	ld (test_peek_seen), a
	ld a, BIOS_OP_PEEK
	rst 0x10
	ld hl, test_peek_seen
	cp (hl)
	jp nz, test_fail
	ld a, BIOS_OP_RX_GET
	rst 0x10
	ld hl, test_peek_seen
	cp (hl)
	jp nz, test_fail
	ld a, BIOS_OP_RX_GET
	rst 0x10
	jp nc, test_fail
	ld hl, msg_peek_pass
	call test_puts

;; RX_GET dequeues two distinct bytes and reports empty afterward.
	ld hl, msg_rxget_ready
	call test_puts
test_rxget_wait_first:
	ld a, BIOS_OP_RX_GET
	rst 0x10
	jr c, test_rxget_wait_first
	cp 'R'
	jp nz, test_fail
test_rxget_wait_second:
	ld a, BIOS_OP_RX_GET
	rst 0x10
	jr c, test_rxget_wait_second
	cp 'S'
	jp nz, test_fail
	ld a, BIOS_OP_RX_GET
	rst 0x10
	jp nc, test_fail
	ld hl, msg_rxget_pass
	call test_puts

;; NREAD exact-length tests: one byte, three bytes, and a full 128-byte block.
	ld hl, msg_nread_one_ready
	call test_puts
	ld hl, test_nread_one
	ld bc, 1
	ld a, BIOS_OP_NREAD
	rst 0x10
	ld a, (test_nread_one)
	cp '1'
	jp nz, test_fail
	ld hl, msg_nread_one_pass
	call test_puts

	ld hl, msg_nread_three_ready
	call test_puts
	ld hl, test_nread_three
	ld bc, 3
	ld a, BIOS_OP_NREAD
	rst 0x10
	ld a, (test_nread_three)
	cp 'A'
	jp nz, test_fail
	ld a, (test_nread_three+1)
	cp 'B'
	jp nz, test_fail
	ld a, (test_nread_three+2)
	cp 'C'
	jp nz, test_fail
	ld hl, msg_nread_three_pass
	call test_puts

	ld hl, msg_nread_128_ready
	call test_puts
	ld hl, test_nread_128
	ld bc, 128
	ld a, BIOS_OP_NREAD
	rst 0x10
	ld ix, test_nread_128
	ld b, 128
test_nread_128_check:
	ld a, (ix+0)
	cp 'N'
	jp nz, test_fail
	inc ix
	djnz test_nread_128_check
	ld hl, msg_nread_128_pass
	call test_puts

;; XMODEM_RX receives two frames through the actual sx sender in testbios.py.
	ld hl, msg_xmodem_ready
	call test_puts
	ld hl, 0x123456
	push hl
	ld hl, test_xmodem_buffer
	ld a, BIOS_OP_XMODEM_RX
	rst 0x10
	ld (test_xmodem_status), a
	pop hl
	ld de, 0x123456
	or a
	sbc hl, de
	jp nz, test_fail_stack
	ld a, (test_xmodem_status)
	or a
	jp nz, test_fail_xmodem_status
	ld ix, test_xmodem_buffer
	ld a, (ix+0)
	cp 'X'
	jp nz, test_fail_xmodem_data
	ld a, (ix+127)
	cp 'X'
	jp nz, test_fail_xmodem_data
	ld ix, test_xmodem_buffer+128
	ld a, (ix+0)
	cp 'X'
	jp nz, test_fail_xmodem_data
	ld ix, test_xmodem_buffer+255
	ld a, (ix+0)
	cp 'X'
	jp nz, test_fail_xmodem_data
	ld ix, test_xmodem_buffer+258
	ld a, (ix+0)
	cp 0x5A
	jp nz, test_fail_xmodem_data
	ld hl, msg_xmodem_pass
	call test_puts

;; Fill all 255 TX ring slots with interrupts masked, then verify full status.
;; The host checks that all queued Q bytes arrive in order after EI.
	ld hl, msg_tx_queue_begin
	call test_puts
	ld a, BIOS_OP_WAIT
	rst 0x10
	di
	ld b, 255
test_tx_fill:
	ld c, 'Q'
	ld a, BIOS_OP_TX_PUT
	rst 0x10
	jp c, test_fail_tx_early
	djnz test_tx_fill
	ld c, '!'
	ld a, BIOS_OP_TX_PUT
	rst 0x10
	jp nc, test_fail_tx_not_full
	ei
	ld hl, msg_tx_queue_pass
	call test_puts

	ld hl, msg_all_pass
	call test_puts
	ld a, BIOS_OP_HALT
	rst 0x10
	ld hl, msg_halt_returned
	call test_puts
	jp test_fail

test_callback:
	ld a, 0x5A
	ret
test_callback_second:
	ld a, 0xA5
	ret

test_puts:
	ld a, BIOS_OP_PUTS
	rst 0x10
	ret

test_fail_stack:
	ld hl, msg_stack_fail
	call test_puts
	jp test_fail
test_fail_tx_early:
	ei
	ld hl, msg_tx_early_fail
	call test_puts
	jp test_fail
test_fail_tx_not_full:
	ei
	ld hl, msg_tx_not_full_fail
	call test_puts
	jp test_fail
test_fail_xmodem_status:
	ld hl, msg_xmodem_status_fail
	call test_puts
	jp test_fail
test_fail_xmodem_data:
	ld hl, msg_xmodem_data_fail
	call test_puts
test_fail:
	ei
	ld hl, msg_fail
	call test_puts
	ld a, BIOS_OP_HALT
	rst 0x10
	jp test_fail

msg_start:             .asciz "TESTBIOS:START\r\n"
msg_putchar_prefix:    .asciz "TESTBIOS:PUTCHAR:"
msg_puts_prefix:       .asciz "TESTBIOS:PUTS:"
msg_puts_one:          .asciz "one"
msg_empty:             .asciz ""
msg_puts_two:          .asciz "two\r\n"
msg_wait_begin:        .asciz "TESTBIOS:WAIT_BEGIN\r\n"
msg_wait_end:          .asciz "TESTBIOS:WAIT_END\r\n"
msg_call_hl_pass:      .asciz "PASS:CALL_HL\r\n"
msg_call_hl_second_pass:.asciz "PASS:CALL_HL_SECOND\r\n"
msg_badop_pass:        .asciz "PASS:BAD_OPERATION\r\n"
msg_empty_pass:        .asciz "PASS:EMPTY_AND_ZERO_NREAD\r\n"
msg_getchar_ready:     .asciz "TESTBIOS:GETCHAR_READY\r\n"
msg_getchar_pass:      .asciz "PASS:GETCHAR\r\n"
msg_getchar_second_ready:.asciz "TESTBIOS:GETCHAR2_READY\r\n"
msg_getchar_second_pass:.asciz "PASS:GETCHAR_SECOND\r\n"
msg_peek_ready:        .asciz "TESTBIOS:PEEK_READY\r\n"
msg_peek_pass:         .asciz "PASS:PEEK_AND_RX_GET\r\n"
msg_rxget_ready:       .asciz "TESTBIOS:RXGET_READY\r\n"
msg_rxget_pass:        .asciz "PASS:RX_GET_MULTI\r\n"
msg_nread_one_ready:   .asciz "TESTBIOS:NREAD1_READY\r\n"
msg_nread_one_pass:    .asciz "PASS:NREAD1\r\n"
msg_nread_three_ready: .asciz "TESTBIOS:NREAD3_READY\r\n"
msg_nread_three_pass:  .asciz "PASS:NREAD3\r\n"
msg_nread_128_ready:   .asciz "TESTBIOS:NREAD128_READY\r\n"
msg_nread_128_pass:    .asciz "PASS:NREAD128\r\n"
msg_xmodem_ready:      .asciz "TESTBIOS:XMODEM_READY\r\n"
msg_xmodem_pass:       .asciz "PASS:XMODEM_RX\r\n"
msg_xmodem_status_fail:.asciz "FAIL:XMODEM_STATUS\r\n"
msg_xmodem_data_fail:  .asciz "FAIL:XMODEM_DATA\r\n"
msg_tx_queue_begin:    .asciz "TESTBIOS:TX_QUEUE_BEGIN\r\n"
msg_tx_queue_pass:     .asciz "PASS:TX_PUT_FULL\r\n"
msg_tx_early_fail:     .asciz "FAIL:TX_PUT_EARLY\r\n"
msg_tx_not_full_fail:  .asciz "FAIL:TX_PUT_NOT_FULL\r\n"
msg_stack_fail:        .asciz "FAIL:XMODEM_STACK\r\n"
msg_all_pass:          .asciz "TESTBIOS:ALL_PASS\r\n"
msg_halt_returned:     .asciz "FAIL:HALT_RETURNED\r\n"
msg_fail:              .asciz "FAIL:ASSERTION\r\n"
msg_crlf:              .asciz "\r\n"

	.align 1
test_peek_seen:        .db 0
test_xmodem_status:    .db 0
test_nread_one:        .db 0
test_nread_three:     .ds 3, 0
test_nread_128:       .ds 128, 0
test_xmodem_buffer:   .ds 260, 0x5A
