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

#define ONCHIP_RAM_BASE 0xFFE000UL
#define ONCHIP_MOS_BASE 0x.......
#define ONCHIP_RAM_SIZE 8192

void (*__enter_bios)(void) = ONCHIP_RAM_BASE;

int main(void)
{
    volatile uint8_t *ram =
        (volatile uint8_t *)ONCHIP_RAM_BASE;


    /* Load BIOS into on chip RAM */
    FILE *f = fopen("EZ80BIOS.bin");

    if (NULL == f) {
      //Some error message
    }      

    if (ONCHIP_RAM_SIZE != fread(ONCHIP_MOS_BASE, ONCHIP_RAM_SIZE, f)) {
      //Some error message
    }

    fclose(f);
    
    /* Starting MOS shutdown */
    puts("Closing MOS\n");
    delay_50ms();

    /* Disable VDI */

    // Send VDU 24 via MOS

    delay_50ms();

    // Turn CTS off on uart0 with a register write


    
    delay_50ms();

    // CRITICAL: no MOS calls after this point
    
    /* Disable ALL interrupts
       As in individually turn them off, not just "di"
    */

    // Disable UART0 interrupt

    // Disable timer interrupts

    

    delay_50ms();    


    //Leave interrupts off until BIOS has set it's stack up
    __asm__("di"); 
    
    /* Move On-Chip RAM */
    IO(RAM_ADDR_U) = 0xFF;            //Top of memory map
    IO(RAM_CTL) = IO(RAM_CTL) | 0xC0; //Ram enabled and default arbitration
    delay_50ms();

    __enter_bios(); //Will never return

    return 0;
}

