#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <ez80f92.h>
#include <agon/mos.h>


static void delay_50ms(void)
{
    volatile uint32_t i;

    for (i = 0; i < 50000UL; i++) {
        __asm__("nop");
    }
}

#define ONCHIP_RAM_LOAD_BASE 0xB7E000UL
#define ONCHIP_RAM_EXEC_BASE 0x00E000UL
#define ONCHIP_RAM_SIZE 8192

void (*__enter_bios)(void) = (void (*)(void))ONCHIP_RAM_EXEC_BASE;

__attribute__((noinline, used, noreturn))
void bios_handoff(void)
{
    /* No MOS calls beyond this point. */
    __asm__("di");

    /* Disable device-level interrupts before disabling the CPU interrupt flag. */
    IO(UART0_IER) = 0x00;
    IO(UART1_IER) = 0x00;
    IO(TMR0_CTL) = 0x00;
    IO(TMR1_CTL) = 0x00;
    IO(TMR2_CTL) = 0x00;
    IO(TMR3_CTL) = 0x00;
    IO(TMR4_CTL) = 0x00;
    IO(TMR5_CTL) = 0x00;
    delay_50ms();

    /* Disable Flash, then map the on-chip SRAM into page zero. */
    IO(FLASH_CTRL) &= (uint8_t)~0x08;
    delay_50ms();
    IO(RAM_ADDR_U) = 0x00;
    IO(RAM_CTL) |= 0x80;
    delay_50ms();

    __enter_bios();
    for (;;) { }
}

int main(void)
{
    /* Load BIOS into on chip RAM */
    FILE *f = fopen("EZ80BIOS.bin", "rb");
    if (NULL == f) {
        puts("Cannot open EZ80BIOS.bin");
        return EXIT_FAILURE;
    }

    if (ONCHIP_RAM_SIZE != fread((void *)ONCHIP_RAM_LOAD_BASE, 1,
                                 ONCHIP_RAM_SIZE, f)) {
        fprintf(stderr, "EZ80BIOS.bin must contain exactly %u bytes\n",
                ONCHIP_RAM_SIZE);
        fclose(f);
        return EXIT_FAILURE;
    }
    fclose(f);
    
    /* Configure UART1 through MOS first and report shutdown on that link. */
    UART uart1Settings = {0};
    uart1Settings.baudRate = 115200;
    uart1Settings.dataBits = 8;
    uart1Settings.stopBits = 1;
    uart1Settings.parity = 0;
    uart1Settings.flowcontrol = 0;
    uart1Settings.eir = 0;
    mos_uopen(&uart1Settings);

    puts("Shutting down MOS");
    static const char shutdownMessage[] = "Shutting down MOS\r\n";
    for (size_t i = 0; i < sizeof(shutdownMessage) - 1; ++i)
        mos_uputc(shutdownMessage[i]);
    mos_uclose();
    delay_50ms();

    /* Send VDU 21 directly to the VDP through the MOS RST 10h vector. */
    __asm__ volatile (
        "ld a, 21\n\t"
        "rst.lis 0x10"
        :
        :
        : "a"
    );
    delay_50ms();


    // CRITICAL: no MOS calls after this point


    // Turn of UART0. Also deasserts UART0 RTS (the output used for hardware flow control).
    IO(UART0_MCTL) = 0; 
    delay_50ms();

    bios_handoff();

    return EXIT_FAILURE;
}

