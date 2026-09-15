/* Proteus SPI slave (mode 0, MSB first).

   Waits for CS low, samples MOSI on SCK rising edges and shifts MISO out on
   SCK falling edges. Sends a fixed byte; the received byte is written to the
   results section.

   SCK = ui_in[0], MOSI = ui_in[1], CS = ui_in[2], MISO = uo_out[0]. */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define SCK_IN 0x100u
#define MOSI_IN 0x200u
#define CS_IN 0x400u
#define MISO_OUT 0x1u

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static int sck(void) { return (PIN_IN & SCK_IN) ? 1 : 0; }
static int mosi(void) { return (PIN_IN & MOSI_IN) ? 1 : 0; }
static int cs(void) { return (PIN_IN & CS_IN) ? 1 : 0; }
static void miso(int b) {
  if (b) {
    PIN_OUT |= MISO_OUT;
  } else {
    PIN_OUT &= ~MISO_OUT;
  }
}

int main(void) {
  PIN_OUT = 0;
  int tx = 0x5A;

  while (cs()) {
  }
  miso((tx >> 7) & 1);
  int rx = 0;
  for (int i = 0; i < 8; i++) {
    while (!sck()) {
    }
    rx = (rx << 1) | mosi();
    while (sck()) {
    }
    if (i < 7) miso((tx >> (6 - i)) & 1);
  }
  while (!cs()) {
  }

  results[0] = (unsigned int)rx;
  results[1] = (unsigned int)tx;
  HALT = 0;
  return 0;
}
