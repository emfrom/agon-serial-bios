;; Public symbols exported by the BIOS. Include this file in BIOS source and
;; in client assembly modules that reference these entry points or data.
	.global bios_entry, bios_uart1_tx_put, bios_uart1_rx_get, bios_wait
	.global io_putchar, io_getchar, io_peek, io_nread, io_puts, io_xmodem_rx
	.global bios_xmodem_wp, bios_uptime_10ms
	.global bios_rs_head, bios_rs_tail, bios_ts_head, bios_ts_tail
	.global bios_rs_overflow, bios_rs_ring, bios_ts_ring
