;; Pointless screen game: move an X with WASD; other recognized keys restart.
;; Screen size is queried with the xterm CSI 18 t window-size request.
	.assume ADL = 1
	.global xwasd
	.section .xwasd,"ax",@progbits

xwasd:
	;; Ask for CSI 8 ; rows ; columns t.
	ld hl, size_query
	call put_string
	call get_char
	cp 0x1B
	jp nz, restart
	call get_char
	cp '['
	jp nz, restart
	call get_char
	cp '8'
	jp nz, restart
	call get_char
	cp ';'
	jp nz, restart

	ld hl, screen_rows
	ld c, ';'
	call parse_decimal
	ld a, (screen_rows)
	or a
	jp z, restart

	ld hl, screen_columns
	ld c, 't'
	call parse_decimal
	ld a, (screen_columns)
	or a
	jp z, restart

	;; Clear the terminal and put the X at the one-based screen center.
	ld hl, clear_screen
	call put_string
	ld a, (screen_rows)
	ld b, a
	srl a
	ld c, a
	ld a, b
	and 1
	add a, c
	ld (cursor_row), a
	ld a, (screen_columns)
	ld b, a
	srl a
	ld c, a
	ld a, b
	and 1
	add a, c
	ld (cursor_column), a
	call draw_x

read_key:
	call get_char
	cp 'w'
	jp z, move_up
	cp 'a'
	jp z, move_left
	cp 's'
	jp z, move_down
	cp 'd'
	jp z, move_right

	;; The other recognized keys restart; all unlisted keys are ignored.
	cp 0x03                    ;; Ctrl-C
	jp z, restart
	cp 0x04                    ;; Ctrl-D
	jp z, restart
	cp ' '
	jp z, restart
	cp 0x0D                    ;; Return (CR)
	jp z, restart
	cp 0x0A                    ;; Accept LF as a Return alias.
	jp z, restart
	jp read_key

move_up:
	ld a, (cursor_row)
	cp 1
	jp z, read_key
	dec a
	ld (target_row), a
	ld a, (cursor_column)
	ld (target_column), a
	jp move_x

move_down:
	ld a, (cursor_row)
	ld b, a
	ld a, (screen_rows)
	cp b
	jp z, read_key
	ld a, b
	inc a
	ld (target_row), a
	ld a, (cursor_column)
	ld (target_column), a
	jp move_x

move_left:
	ld a, (cursor_column)
	cp 1
	jp z, read_key
	dec a
	ld (target_column), a
	ld a, (cursor_row)
	ld (target_row), a
	jp move_x

move_right:
	ld a, (cursor_column)
	ld b, a
	ld a, (screen_columns)
	cp b
	jp z, read_key
	ld a, b
	inc a
	ld (target_column), a
	ld a, (cursor_row)
	ld (target_row), a

move_x:
	;; Erase the old position, update coordinates, then draw the new X.
	call position_cursor
	ld c, ' '
	call put_char
	ld a, (target_row)
	ld (cursor_row), a
	ld a, (target_column)
	ld (cursor_column), a
	call draw_x
	jp read_key

draw_x:
	call position_cursor
	ld c, 'X'
	call put_char
	ret

position_cursor:
	ld c, 0x1B
	call put_char
	ld c, '['
	call put_char
	ld a, (cursor_row)
	call print_decimal
	ld c, ';'
	call put_char
	ld a, (cursor_column)
	call print_decimal
	ld c, 'H'
	call put_char
	ret

;; Print A as an unsigned decimal number in the range 0..255.
print_decimal:
	ld b, 0                    ;; Hundreds digit
print_hundreds:
	cp 100
	jp c, print_hundreds_done
	sub 100
	inc b
	jp print_hundreds
print_hundreds_done:
	push af                    ;; Keep the remainder across BIOS output.
	ld a, b
	or a
	jp z, print_tens_start
	add a, '0'
	ld c, a
	call put_char
print_tens_start:
	pop af
	ld d, 0                    ;; Tens digit
print_tens:
	cp 10
	jp c, print_tens_done
	sub 10
	inc d
	jp print_tens
print_tens_done:
	push af
	ld a, d
	or a
	jp nz, print_tens_digit
	ld a, b
	or a
	jp z, print_ones
print_tens_digit:
	ld a, d
	add a, '0'
	ld c, a
	call put_char
print_ones:
	pop af
	add a, '0'
	ld c, a
	call put_char
	ret

;; Parse decimal digits at HL, stopping at delimiter C; return delimiter in A.
;; Values above 255 and malformed digits cause a soft restart.
parse_decimal:
	xor a
	ld (hl), a
parse_decimal_next:
	call get_char
	cp c
	ret z
	sub '0'
	jp c, restart
	cp 10
	jp nc, restart
	ld b, a                    ;; New digit
	ld a, (hl)
	cp 25
	jp c, parse_decimal_accumulate
	jp nz, restart
	ld a, b
	cp 6
	jp nc, restart
parse_decimal_accumulate:
	ld a, (hl)
	ld d, a
	add a, a                   ;; 2 * value
	ld e, a
	add a, a                   ;; 4 * value
	add a, a                   ;; 8 * value
	add a, e                   ;; 10 * value
	add a, b
	ld (hl), a
	jp parse_decimal_next

;; GETCHAR returns the byte in A. Preserve the parser's working registers.
get_char:
	push bc
	push de
	push hl
	ld a, 0x01                 ;; BIOS_OP_GETCHAR
	rst 0x10
	pop hl
	pop de
	pop bc
	ret

;; PUTCHAR takes the byte in C. Preserve the caller's working registers.
put_char:
	push bc
	push de
	push hl
	ld a, 0x00                 ;; BIOS_OP_PUTCHAR
	rst 0x10
	pop hl
	pop de
	pop bc
	ret

put_string:
	push bc
	push de
	push hl
	ld a, 0x04                 ;; BIOS_OP_PUTS
	rst 0x10
	pop hl
	pop de
	pop bc
	ret

restart:
	rst 0x00                   ;; BIOS soft restart; does not return.

size_query:
	.byte 0x1B, '[', '1', '8', 't', 0
clear_screen:
	.byte 0x1B, '[', '2', 'J', 0

screen_rows:       .db 0
screen_columns:    .db 0
cursor_row:        .db 0
cursor_column:     .db 0
target_row:        .db 0
target_column:     .db 0
