/* UART receiver with even parity checking.

   Waits for the start bit, samples 8 data bits (LSB first), then the parity
   bit and stop bit. Returns the byte, or marks a parity/framing error.

   RX = ui_in[0]. */

#define PINS 0x20000000u
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define RX_IN 0x100u
#define RX_SAMPLE 30 /* to the middle of the start bit */
#define BIT_CYCLES 60

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static inline void delay_cycles(unsigned int n) {
  __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" : : "r"(n));
}
static int rx(void) { return (PIN_IN & RX_IN) ? 1 : 0; }

int main(void) {
  while (rx()) {
  }
  delay_cycles(RX_SAMPLE);

  int b = 0;
  int p = 0;
  for (int i = 0; i < 8; i++) {
    delay_cycles(BIT_CYCLES);
    int bit = rx();
    b |= bit << i;
    p ^= bit;
  }
  delay_cycles(BIT_CYCLES);
  int par = rx();
  delay_cycles(BIT_CYCLES);
  int stop = rx();

  int err = 0;
  if (par != p) err = 1; /* parity error */
  if (stop != 1) err = 2; /* framing error */

  results[0] = (unsigned int)b;
  results[1] = (unsigned int)err;
  HALT = 0;
  return 0;
}
