;; EZ80BIOS.s — BIOS code and hot data occupy internal SRAM at 0xE000..0xFFFF.
;; The image is loaded at 0xB7E000, then RAM_ADDR_U=0 maps it to page zero.
;; External SRAM is mapped at 0x000000..0x07FFFF; internal SRAM shadows E000-FFFF.
;; build.sh extracts this absolute range into the 8192-byte BIOS image.
;; All non-emitting hardware/bit constants are collected in the .set block at EOF.

	.assume ADL = 1

;; RST 10h API operation numbers (see BIOS_API.md).
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
	.set BIOS_OP_VECTOR_ADD, 0x0B
	.set BIOS_OP_VECTOR_REMOVE, 0x0C
	.set BIOS_OP_COUNT, 0x0D
	.set BIOS_STATUS_BAD_OPERATION, 0xFF
	.set BIOS_STATUS_VECTOR_UNSUPPORTED, 1
	.set BIOS_STATUS_VECTOR_FULL, 2
	.set BIOS_STATUS_VECTOR_NOT_FOUND, 3

	.section .bios,"ax",@progbits
	.org 0xE000

;; MOS enters here after loading the BIOS into internal SRAM.
;; Hard start restores the platform memory map, then jumps to persistent soft start.
	.global bios_entry                  ;; Linker entry, not a client API call.
bios_ivt_table:
bios_entry:
bios_hard_start:
	di
	;; Internal SRAM must remain executable while Flash and CS0 are remapped.
	in0 a, (FLASH_CTRL)
	and FLASH_DISABLE_MASK
	out0 (FLASH_CTRL), a
	xor a
	out0 (RAM_ADDR_U), a
	in0 a, (RAM_CTL)
	or RAM_CTL_ONCHIP_SRAM_ENABLE
	out0 (RAM_CTL), a
	;; Map all 512 KiB of external SRAM to pages 0x00..0x07.
	ld a, EXTERNAL_RAM_FIRST_PAGE
	out0 (CS0_UBR), a
	out0 (CS0_LBR), a
	ld a, EXTERNAL_RAM_LAST_PAGE
	out0 (CS0_UBR), a

	;; Hard start is transient: after its jump, the runtime IVT replaces it.
	jp.lil bios_soft_start
	;; Packed runtime state begins immediately after the 0x68-byte IVT.
	.org 0xE068
bios_rs_head:                  .db 0
bios_rs_tail:                  .db 0
bios_ts_head:                  .db 0
bios_ts_tail:                  .db 0
bios_rs_overflow:              .db 0
bios_uptime_10ms:              .ds 3, 0
bios_xmodem_wp:                .ds 3, 0
bios_xmodem_remaining:         .ds 3, 0
bios_xmodem_retry_armed:       .db 0
bios_xmodem_start_flag:        .db 0
bios_timer0_isr_active:        .db 0
bios_xmodem_expected:          .db 0
bios_xmodem_have_block:        .db 0
bios_xmodem_block:             .db 0
bios_xmodem_complement:        .db 0
bios_xmodem_header_ok:         .db 0
bios_xmodem_store:             .db 0
bios_xmodem_data_count:        .db 0
bios_xmodem_byte:              .db 0
bios_xmodem_received_crc_hi:   .db 0
bios_xmodem_received_crc_lo:   .db 0
bios_nread_dest:               .ds 3, 0
bios_timer0_extensions_present:.db 0
bios_timer0_extensions:        .ds 24, 0
bios_vector_op_status:         .db 0
bios_vector_request_handler:   .ds 3, 0
	;; The stack and byte rings have fixed, compile-time bases. The rings must be
	;; page-aligned because their hot paths replace only the low address byte.
	.org 0xE100
bios_stack:
	.ds 256, 0
	.set bios_stack_top, 0xE200

	.org 0xE200
bios_rs_ring:
bios_ringbuffer_in:
	.ds 256, 0

	.org 0xE300
bios_ts_ring:
bios_ringbuffer_out:
	.ds 256, 0

;; Software RST stubs copied to external SRAM at 0x000000..0x00003F.
;; RST 00h restarts; RST 10h enters the public API dispatcher; others halt.
	.org 0xE400
bios_rst_vector_defaults:
	jp.lil bios_soft_start
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0
	jp.lil bios_api_dispatch
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0
	jp.lil bios_halt
	.ds 3, 0

;; Immutable default copy of the peripheral IVT; active IVT is at E000.
	.org 0xE440
bios_ivt_defaults:
	.dw 0, 0, 0, 0
	.dw __bios_unhandled_isr ; 0x08 Flash
	.dw __bios_timer0_isr    ; 0x0A PRT0
	.dw __bios_unhandled_isr ; 0x0C PRT1
	.dw __bios_unhandled_isr ; 0x0E PRT2
	.dw __bios_unhandled_isr ; 0x10 PRT3
	.dw __bios_unhandled_isr ; 0x12 PRT4
	.dw __bios_unhandled_isr ; 0x14 PRT5
	.dw __bios_unhandled_isr ; 0x16 RTC
	.dw __bios_unhandled_isr ; 0x18 UART0
	.dw __bios_uart1_isr     ; 0x1A UART1
	.dw __bios_unhandled_isr ; 0x1C I2C
	.dw __bios_unhandled_isr ; 0x1E SPI
	.rept 8
	.dw 0
	.endr
	.dw __bios_unhandled_isr ; 0x30 Port B0
	.dw __bios_unhandled_isr ; 0x32 Port B1
	.dw __bios_unhandled_isr ; 0x34 Port B2
	.dw __bios_unhandled_isr ; 0x36 Port B3
	.dw __bios_unhandled_isr ; 0x38 Port B4
	.dw __bios_unhandled_isr ; 0x3A Port B5
	.dw __bios_unhandled_isr ; 0x3C Port B6
	.dw __bios_unhandled_isr ; 0x3E Port B7
	.dw __bios_unhandled_isr ; 0x40 Port C0
	.dw __bios_unhandled_isr ; 0x42 Port C1
	.dw __bios_unhandled_isr ; 0x44 Port C2
	.dw __bios_unhandled_isr ; 0x46 Port C3
	.dw __bios_unhandled_isr ; 0x48 Port C4
	.dw __bios_unhandled_isr ; 0x4A Port C5
	.dw __bios_unhandled_isr ; 0x4C Port C6
	.dw __bios_unhandled_isr ; 0x4E Port C7
	.dw __bios_unhandled_isr ; 0x50 Port D0
	.dw __bios_unhandled_isr ; 0x52 Port D1
	.dw __bios_unhandled_isr ; 0x54 Port D2
	.dw __bios_unhandled_isr ; 0x56 Port D3
	.dw __bios_unhandled_isr ; 0x58 Port D4
	.dw __bios_unhandled_isr ; 0x5A Port D5
	.dw __bios_unhandled_isr ; 0x5C Port D6
	.dw __bios_unhandled_isr ; 0x5E Port D7
	.dw 0, 0, 0, 0

;; Runtime code and all BIOS functions follow the fixed workspace/templates.
	.org 0xE4A8
;; Warm restart entry. RST 00h lands here after the low vectors are installed.
bios_soft_start:
	di
	ld sp, bios_stack_top
	;; Quiesce interrupt sources left enabled by the previous program.
	xor a
	out0 (UART0_IER), a
	out0 (UART1_IER), a
	out0 (TMR0_CTL), a
	out0 (TMR1_CTL), a
	out0 (TMR2_CTL), a
	out0 (TMR3_CTL), a
	out0 (TMR4_CTL), a
	out0 (TMR5_CTL), a
	;; Reading each control register clears a pending timer interrupt flag.
	in0 a, (TMR0_CTL)
	in0 a, (TMR1_CTL)
	in0 a, (TMR2_CTL)
	in0 a, (TMR3_CTL)
	in0 a, (TMR4_CTL)
	in0 a, (TMR5_CTL)

	;; Reinstall software RST stubs and the peripheral IVT defaults.
	ld hl, bios_rst_vector_defaults
	ld de, BIOS_ZERO
	ld bc, BIOS_RST_VECTOR_BYTES
	ldir
	ld hl, bios_ivt_defaults
	ld de, bios_ivt_table
	ld bc, BIOS_IVT_BYTES
	ldir
	ld a, BIOS_IVT_PAGE
	ld i, a

	;; Clear VSync's PB1 alternate function and pending edge before enabling IRQs.
	in0 a, (PB_DR)
	or PORTB1_MASK
	out0 (PB_DR), a
	in0 a, (PB_ALT1)
	and PORTB1_MASK_CLEAR
	out0 (PB_ALT1), a
	in0 a, (PB_ALT2)
	and PORTB1_MASK_CLEAR
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
	ld (bios_timer0_extensions_present), a
	ld (bios_xmodem_start_flag), a
	ld (bios_timer0_isr_active), a
	ld hl, BIOS_ZERO
	ld ix, bios_timer0_extensions
	ld b, BIOS_TIMER0_EXTENSION_SLOTS
__bios_clear_timer0_extensions:
	ld (ix+0), hl
	inc ix
	inc ix
	inc ix
	djnz __bios_clear_timer0_extensions

	;; Use only RTS from MCTL; RTS is active-low at the pin.
	ld a, UART1_MCTL_RTS          ;; DTR stays off.
	out0 (UART1_MCTL), a

	;; Copy the NUL-terminated map message to the first external RAM address.
	ld hl, bios_memory_mapped_message
	ld de, EXTERNAL_RAM_START_ADDRESS
__bios_copy_memory_message:
	ld a, (hl)
	ld (de), a
	inc hl
	inc de
	or a
	jr nz, __bios_copy_memory_message

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
	ld hl, EXTERNAL_RAM_START_ADDRESS
	ld bc, XMODEM_BOOT_MAX_SIZE
	call io_xmodem_rx
	or a
	jr nz, __io_xmodem_failed
	ld hl, bios_xmodem_complete_message
	call io_puts
	ld hl, bios_xmodem_press_r_message
	call io_puts
__bios_wait_for_run:
	call io_getchar
	cp 'R'
	jr z, __bios_run_loaded_program
	cp 'r'
	jr nz, __bios_wait_for_run
__bios_run_loaded_program:
	xor a
	jp EXTERNAL_RAM_START_ADDRESS
__io_xmodem_failed:
	ld hl, bios_xmodem_failed_message
	call io_puts

__bios_idle:
	halt
	jr __bios_idle

__bios_unhandled_isr:
	reti.l

;; UART1 interrupt service routine. RX is drained completely into rs; TX is
;; filled in 16-byte FIFO bursts from ts. Preserve the interrupted context.
__bios_uart1_isr:
	push af
	push bc
	push de
	push hl

;; Handle one IIR cause per entry. Any remaining enabled cause retriggers
;; after RETI; do not spin rereading IIR inside the ISR.
__bios_uart1_irq_next:
	in0 a, (UART1_IIR)
	ld b, a
	and UART1_IIR_INTBIT
	jp nz, __bios_uart1_irq_done
	ld a, b
	and UART1_IIR_INSTS_MASK
	cp UART1_IIR_LINE_STATUS     ;; Receiver line-status error
	jr z, __bios_uart1_irq_line_status
	cp UART1_IIR_RX_DATA_READY
	jr z, __bios_uart1_rx_service
	cp UART1_IIR_RX_TIMEOUT
	jr z, __bios_uart1_rx_service
	cp UART1_IIR_TX_EMPTY         ;; Transmit FIFO empty
	jp z, __bios_uart1_tx_service

	;; Modem-status interrupts are disabled; clear any unexpected cause.
	in0 a, (UART1_MSR)
	jp __bios_uart1_irq_done

__bios_uart1_irq_line_status:
	in0 a, (UART1_LSR)            ;; Reading LSR clears line-status causes.

__bios_uart1_rx_service:
	call __bios_uart1_rx_drain
	jp __bios_uart1_irq_done

;; Drain all available hardware RX bytes into rs. Clobbers AF/BC/DE/HL; its
;; UART and timer ISR callers already preserve the interrupted register set.
__bios_uart1_rx_drain:
__bios_uart1_rx_loop:
	in0 a, (UART1_LSR)
	and UART1_LSR_DR              ;; Receiver data ready?
	jr z, __bios_uart1_rx_done
	in0 a, (UART1_RBR)
	ld c, a                       ;; Preserve byte while checking ring space.
	ld a, (bios_rs_head)
	ld b, a                       ;; B = current head
	inc a
	ld d, a                       ;; D = next head
	ld a, (bios_rs_tail)
	cp d
	jr z, __bios_uart1_rx_full      ;; One slot is reserved to distinguish full.

	ld hl, bios_ringbuffer_in
	ld l, b
	ld (hl), c
	ld a, b
	inc a
	ld (bios_rs_head), a
	jr __bios_uart1_rx_loop

__bios_uart1_rx_full:
	ld a, (bios_rs_overflow)
	inc a
	ld (bios_rs_overflow), a
	jr __bios_uart1_rx_loop

__bios_uart1_rx_done:
	call __bios_uart1_update_rts
	ret

;; PRT0 wakes HALT, advances uptime, and drains residual UART1 FIFO bytes.
__bios_timer0_isr:
	push af
	push bc
	push de
	push hl
	push ix
	push iy
	ld a, 1
	ld (bios_timer0_isr_active), a
__bios_timer0_user_extensions:
	ld a, (bios_timer0_extensions_present)
	and 1
	jr nz, __bios_timer0_extension_setup
__bios_timer0_after_extensions:
	in0 a, (TMR0_CTL)             ;; Reading CTL clears the timer IRQ flag.
	ld hl, (bios_uptime_10ms)
	inc hl
	ld (bios_uptime_10ms), hl
	call __bios_uart1_rx_drain
	xor a
	ld (bios_timer0_isr_active), a
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	pop af
	ei
	reti.l

;; Push the continuation and each occupied slot. The last occupied slot is
;; first in the chain; each handler exits with POP HL / JP (HL).
__bios_timer0_extension_setup:
	ld hl, __bios_timer0_after_extensions
	push hl
	ld ix, bios_timer0_extensions
	ld b, BIOS_TIMER0_EXTENSION_SLOTS
__bios_timer0_extension_scan:
	ld hl, (ix+0)
	ld de, BIOS_ZERO
	or a
	sbc hl, de
	jr z, __bios_timer0_extension_next
	ld hl, (ix+0)
	push hl
__bios_timer0_extension_next:
	inc ix
	inc ix
	inc ix
	djnz __bios_timer0_extension_scan
	pop hl
	jp (hl)

;; ISR continuation: the dispatcher has saved the interrupted register set.
;; A THRE interrupt means the hardware TX FIFO is empty. Fill up to all 16
;; slots and tail-jump to the ISR epilogue.
__bios_uart1_tx_service:
	ld c, UART1_TX_FIFO_CAPACITY
__bios_uart1_tx_loop:
	ld a, (bios_ts_tail)
	ld b, a
	ld a, (bios_ts_head)
	cp b
	jr z, __bios_uart1_tx_disable

	ld hl, bios_ringbuffer_out
	ld l, b
	ld a, (hl)
	out0 (UART1_THR), a
	inc b
	ld a, b
	ld (bios_ts_tail), a
	dec c
	jr nz, __bios_uart1_tx_loop

	;; The FIFO is full. If that also emptied ts, stop empty-FIFO IRQs.
	ld a, (bios_ts_head)
	ld b, a
	ld a, (bios_ts_tail)
	cp b
	jr z, __bios_uart1_tx_disable
	call __bios_uart1_tie_enable
	jp __bios_uart1_irq_done

__bios_uart1_tx_disable:
	call __bios_uart1_tie_disable
	jp __bios_uart1_irq_done

__bios_uart1_tie_enable:
	push af
	in0 a, (UART1_IER)
	or UART1_IER_TIE              ;; Keep refilling while software TX data remains.
	out0 (UART1_IER), a
	pop af
	ret

__bios_uart1_tie_disable:
	push af
	in0 a, (UART1_IER)
	and UART1_IER_TIE_CLEAR       ;; Preserve RX and line-status enables.
	out0 (UART1_IER), a
	pop af
	ret

__bios_uart1_irq_done:
	pop hl
	pop de
	pop bc
	pop af
	ei                             ;; Enable after the following RETI.L.
	reti.l

;; Hysteresis: deassert RTS below 33 free slots; reassert only at 133 free
;; slots (one complete XMODEM/CRC packet). Keep the current state in between.
__bios_uart1_update_rts:
	push af
	push bc
	ld a, (bios_rs_tail)
	ld b, a
	ld a, (bios_rs_head)
	ld c, a
	ld a, b
	sub c
	dec a                         ;; free = tail - head - 1 (modulo 256)
	cp BIOS_RS_RTS_LOW_WATERMARK
	jr c, __bios_uart1_rts_deassert
	cp BIOS_RS_RTS_REASSERT_WATERMARK
	jr c, __bios_uart1_update_rts_done ;; Preserve RTS in the hysteresis band.
	ld a, UART1_MCTL_RTS          ;; MCTL RTS=1 drives active-low RTS asserted.
	out0 (UART1_MCTL), a
	jr __bios_uart1_update_rts_done
__bios_uart1_rts_deassert:
	xor a                         ;; MCTL RTS=0 deasserts active-low RTS.
	out0 (UART1_MCTL), a
__bios_uart1_update_rts_done:
	pop bc
	pop af
	ret

;; Busy-wait for about 50 ms at 18.432 MHz (~921,600 CPU cycles).
;; This uses only CPU cycles; no peripheral timer is required.
bios_wait:
	push af
	push bc
	push de
	ld d, BIOS_WAIT_OUTER
__bios_wait_outer:
	ld c, 0
__bios_wait_middle:
	ld b, BIOS_WAIT_INNER
__bios_wait_inner:
	djnz __bios_wait_inner
	dec c
	jr nz, __bios_wait_middle
	dec d
	jr nz, __bios_wait_outer
	pop de
	pop bc
	pop af
	ret

;; Enter the BIOS idle loop without returning; interrupts continue to run.
bios_halt:
	ei
	jp __bios_idle

;; Public software-call entry. Index a 24-bit address table using A, restore
;; the argument registers, then jump through IX. IX is caller-saved by contract.
bios_api_dispatch:
	cp BIOS_OP_COUNT
	jr nc, __bios_api_bad_operation
	push bc
	push de
	push hl
	ld hl, BIOS_ZERO
	ld l, a
	add hl, hl
	add hl, hl
	ld de, bios_api_jump_table
	add hl, de
	ld ix, (hl)
	pop hl
	pop de
	pop bc
	jp (ix)
__bios_api_bad_operation:
	ld a, BIOS_STATUS_BAD_OPERATION
	or a
	ret

;; Register/remove PRT0 extensions. B is the IVECT value, HL the handler.
;; Duplicate addresses occupy separate slots; removal clears all matches.
bios_vector_add:
	push bc
	push de
	push hl
	push ix
	push iy
	ld a, i
	push af
	di
	ld a, b
	cp TIMER0_IVECT
	jp nz, __bios_vector_unsupported
	ld (bios_vector_request_handler), hl
	ld de, BIOS_ZERO
	or a
	sbc hl, de
	jp z, __bios_vector_unsupported
	ld ix, bios_timer0_extensions
	ld b, BIOS_TIMER0_EXTENSION_SLOTS
__bios_vector_add_scan:
	ld a, (ix+0)
	or (ix+1)
	or (ix+2)
	jr z, __bios_vector_add_slot
	inc ix
	inc ix
	inc ix
	djnz __bios_vector_add_scan
	ld a, BIOS_STATUS_VECTOR_FULL
	jp __bios_vector_operation_finish
__bios_vector_add_slot:
	ld hl, (bios_vector_request_handler)
	ld (ix+0), hl
	ld a, 1
	ld (bios_timer0_extensions_present), a
	xor a
	jp __bios_vector_operation_finish

bios_vector_remove:
	push bc
	push de
	push hl
	push ix
	push iy
	ld a, i
	push af
	di
	ld a, b
	cp TIMER0_IVECT
	jp nz, __bios_vector_unsupported
	ld (bios_vector_request_handler), hl
	ld de, BIOS_ZERO
	or a
	sbc hl, de
	jp z, __bios_vector_missing
	ld ix, bios_timer0_extensions
	ld b, BIOS_TIMER0_EXTENSION_SLOTS
	ld c, 0
__bios_vector_remove_scan:
	ld a, (bios_vector_request_handler+0)
	cp (ix+0)
	jr nz, __bios_vector_remove_next
	ld a, (bios_vector_request_handler+1)
	cp (ix+1)
	jr nz, __bios_vector_remove_next
	ld a, (bios_vector_request_handler+2)
	cp (ix+2)
	jr nz, __bios_vector_remove_next
	xor a
	ld (ix+0), a
	ld (ix+1), a
	ld (ix+2), a
	ld c, 1
__bios_vector_remove_next:
	inc ix
	inc ix
	inc ix
	djnz __bios_vector_remove_scan
	ld ix, bios_timer0_extensions
	ld b, BIOS_TIMER0_EXTENSION_SLOTS
__bios_vector_remove_check_empty:
	ld a, (ix+0)
	or (ix+1)
	or (ix+2)
	jr nz, __bios_vector_remove_done
	inc ix
	inc ix
	inc ix
	djnz __bios_vector_remove_check_empty
	xor a
	ld (bios_timer0_extensions_present), a
__bios_vector_remove_done:
	ld a, c
	or a
	jp z, __bios_vector_missing
	xor a
	jp __bios_vector_operation_finish

__bios_vector_unsupported:
	ld a, BIOS_STATUS_VECTOR_UNSUPPORTED
	jp __bios_vector_operation_finish
__bios_vector_missing:
	ld a, BIOS_STATUS_VECTOR_NOT_FOUND
__bios_vector_operation_finish:
	ld (bios_vector_op_status), a
	ld a, (bios_timer0_isr_active)
	or a
	jp nz, __bios_vector_restore_without_ei
	pop af
	jp po, __bios_vector_restore_registers
	ei
	jp __bios_vector_restore_registers
__bios_vector_restore_without_ei:
	pop af
__bios_vector_restore_registers:
	pop iy
	pop ix
	pop hl
	pop de
	pop bc
	ld a, (bios_vector_op_status)
	or a
	ret

;; Four-byte entries hold 24-bit target addresses plus one unused byte.
bios_api_jump_table:
	.long io_putchar
	.long io_getchar
	.long io_peek
	.long io_nread
	.long io_puts
	.long io_xmodem_rx
	.long bios_uart1_tx_put
	.long bios_uart1_rx_get
	.long bios_wait
	.long bios_halt
	.long __bios_api_call_hl
	.long bios_vector_add
	.long bios_vector_remove
__bios_api_call_hl:
	jp (hl)

	.include "bios/EZ80IO.s"

bios_loaded_message:
	.asciz "BIOS Loaded\r\n"

bios_memory_mapped_message:
	.asciz "External RAM 0x000000-0x07FFFF; programs at 0x010000\r\n"
bios_xmodem_loading_message:
	;; Keep uppercase 'C' out of pre-handshake output: senders treat it as CRC request.
	.asciz "Waiting for XMODEM at 0x010000\r\n"
bios_xmodem_complete_message:
	.asciz "Load complete\r\n"
bios_xmodem_press_r_message:
	.asciz "Press R to run\r\n"
bios_xmodem_failed_message:
	.asciz "XMODEM-CRC receive failed\r\n"

;; the eZ80F92 product specification. Keep all hardware values here.
	.set UART0_IER, 0xC1
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
	.set TMR1_CTL, 0x83
	.set TMR2_CTL, 0x86
	.set TMR3_CTL, 0x89
	.set TMR4_CTL, 0x8C
	.set TMR5_CTL, 0x8F
	.set PB_DR, 0x9A
	.set PB_ALT1, 0x9C
	.set PB_ALT2, 0x9D
	.set RAM_CTL, 0xB4
	.set RAM_ADDR_U, 0xB5
	.set FLASH_CTRL, 0xF8
	.set PC_DDR, 0x9F
	.set PC_ALT1, 0xA0
	.set PC_ALT2, 0xA1
	.set CS0_LBR, 0xA8
	.set CS0_UBR, 0xA9

	.set EXTERNAL_RAM_FIRST_PAGE, 0x00
	.set EXTERNAL_RAM_LAST_PAGE, 0x07
	.set EXTERNAL_RAM_START_ADDRESS, 0x010000
	.set XMODEM_LAST_SAFE_FRAME_START, 0x07FF80
	.set XMODEM_BOOT_MAX_SIZE, 0x070000
	.set BIOS_RST_VECTOR_BYTES, 0x40
	.set BIOS_IVT_BYTES, 0x68
	.set BIOS_IVT_PAGE, 0xE0
	.set FLASH_DISABLE_MASK, 0xF7
	.set RAM_CTL_ONCHIP_SRAM_ENABLE, 0x80
	.set PORTB1_MASK, 0x02
	.set PORTB1_MASK_CLEAR, 0xFD
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
	.set TIMER0_IVECT, 0x0A
	.set BIOS_TIMER0_EXTENSION_SLOTS, 8
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
	.set BIOS_RS_RTS_LOW_WATERMARK, 33
	.set BIOS_RS_RTS_REASSERT_WATERMARK, 133
