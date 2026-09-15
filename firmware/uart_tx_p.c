/* UART transmitter with even parity and CTS flow control.

   Waits for CTS low (clear to send), then sends one byte as
   start + 8 data (LSB first) + even parity + stop.

   TX = uo_out[0], CTS = ui_in[1]. */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define UART_TX 0x1u
#define CTS_IN 0x200u
#define BIT_CYCLES 60

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static inline void delay_cycles(unsigned int n) {
  __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" : : "r"(n));
}
static int cts(void) { return (PIN_IN & CTS_IN) ? 1 : 0; }
static void txb(int b) {
  if (b) {
    PIN_OUT |= UART_TX;
  } else {
    PIN_OUT &= ~UART_TX;
  }
}

int main(void) {
  PIN_OUT = 0;
  txb(1); /* idle high */
  int b = 0x41; /* 'A' */
  int p = 0;
  for (int i = 0; i < 8; i++) p ^= (b >> i) & 1;

  while (cts()) {
  } /* flow control */
  txb(0);
  delay_cycles(BIT_CYCLES);
  for (int i = 0; i < 8; i++) {
    txb((b >> i) & 1);
    delay_cycles(BIT_CYCLES);
  }
  txb(p); /* even parity */
  delay_cycles(BIT_CYCLES);
  txb(1); /* stop */
  delay_cycles(BIT_CYCLES);

  results[0] = (unsigned int)b;
  results[1] = (unsigned int)p;
  HALT = 0;
  return 0;
}
