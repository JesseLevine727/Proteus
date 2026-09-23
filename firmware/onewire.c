/* 1-Wire master (Dallas/Maxim), open-drain on uio[0].

   1-Wire is nothing like UART/SPI/I2C/CAN: a single wire, open-drain, with
   microsecond-scale reset/presence pulses and per-bit time slots. It is not
   on the competition's list of protocols, so implementing it in firmware with
   no RTL change is a direct demonstration of post-fabrication
   reprogrammability.

   The master issues a reset, checks for a presence pulse, writes the
   Skip-ROM command (0xCC) and a byte, then reads a byte. */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define OW_OE 0x10000u
#define OW_IN 0x10000u

/* Scaled timings (cycles). Real 1-Wire is in microseconds; these keep the
   simulation short while preserving the slot structure. */
#define T_RESET 480
#define T_PRESENCE 120
#define T_SLOT 60
#define T_WRITE1 6
#define T_READ 15

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static inline void delay_cycles(unsigned int n) {
  __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" : : "r"(n));
}
static void ow_low(void) { PIN_OE |= OW_OE; }
static void ow_release(void) { PIN_OE &= ~OW_OE; }
static int ow_read(void) { return (PIN_IN & OW_IN) ? 1 : 0; }

static int ow_reset(void) {
  ow_low();
  delay_cycles(T_RESET);
  ow_release();
  delay_cycles(T_READ);
  int presence = ow_read(); /* 0 = a device pulled the line low */
  delay_cycles(T_PRESENCE);
  return presence;
}

static void ow_write_bit(int b) {
  ow_low();
  if (b) {
    delay_cycles(T_WRITE1);
    ow_release();
    delay_cycles(T_SLOT);
  } else {
    delay_cycles(T_SLOT);
    ow_release();
    delay_cycles(T_SLOT);
  }
}

static int ow_read_bit(void) {
  ow_low();
  delay_cycles(T_WRITE1);
  ow_release();
  delay_cycles(T_READ);
  int b = ow_read();
  delay_cycles(T_SLOT);
  return b;
}

static void ow_write_byte(int b) {
  for (int i = 0; i < 8; i++) ow_write_bit((b >> i) & 1);
}

static int ow_read_byte(void) {
  int b = 0;
  for (int i = 0; i < 8; i++) b |= ow_read_bit() << i;
  return b;
}

int main(void) {
  PIN_OUT = 0;
  PIN_OE = 0;

  int presence = ow_reset();
  ow_write_byte(0xCC); /* skip ROM */
  ow_write_byte(0xA5);
  int rd = ow_read_byte();

  results[0] = (unsigned int)presence; /* 0 = present */
  results[1] = (unsigned int)rd;
  HALT = 0;
  return 0;
}
