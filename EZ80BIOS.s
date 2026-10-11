;; EZ80BIOS.s — 8 KiB BIOS image loaded at 0xFFE000 before SRAM remapping.
;; After RAM_ADDR_U=0, the same SRAM bytes appear at 0x00E000..0x00FFFF.
;; With I=0xE0, the eZ80F92 IVT slots below are in this zero-wait-state SRAM.
;; Configure the assembler/linker to emit a flat binary exactly 8192 bytes long.

	.assume ADL = 1
	.org 0x0000

;; The ADL-mode absolute JP occupies four bytes, using the otherwise-unused
;; vector slots at offsets 0x00 and 0x02. Keep this entry before the IVT.
bios_entry:
	jp bios_start

;; The remaining unused vector slots at 0x04 and 0x06 are zeroed.
	.org 0x0004
bios_unused_04: .dw 0
bios_unused_06: .dw 0

;; F92 vector entries are 16-bit ISR addresses, little-endian, at I:IVECT.
	.org 0x0008
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

	.org 0x0068
bios_start:
	di
	ld sp, bios_stack_top
	;; TODO: Initialize hardware and main loop.

bios_halt:
	halt
	jr bios_halt

bios_unhandled_isr:
	reti.l

bios_uart1_isr:
	;; TODO: Service UART1, then return from the interrupt.
	reti.l


	.org 0x1D00
bios_ringbuffer_in:
	.ds 256, 0

	.org 0x1E00
bios_ringbuffer_out:
	.ds 256, 0

	.org 0x1F00
bios_stack:
	.ds 256, 0
	.set bios_stack_top, 0x010000
