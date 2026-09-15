/* Proteus CAN 2.0A firmware receiver.

   Waits for the SOF, samples the wired-AND bus at a fixed bit period in a
   constant-time loop (so the sample point never drifts), then de-stuffs and
   decodes a standard data frame and checks CRC-15.

   CAN_RX = ui_in[0]

   Limitation: the ACK slot is not driven yet. The receiver decodes but does
   not acknowledge; ACK generation is a follow-up. */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)
#define CAN_RX_BIT 0x100u

/* RX_SAMPLE: from the detected SOF edge to the SOF sample point.
   RX_BIT: per-bit period (tuned to match the transmitter). */
#define RX_SAMPLE 104
#define RX_BIT 212
#define MAXBITS 100

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static inline void delay_cycles(unsigned int n) {
  __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" : : "r"(n));
}

static inline int bus_level(void) { return (PIN_IN & CAN_RX_BIT) ? 1 : 0; }

static unsigned int crc15(const unsigned char *buf, int n) {
  unsigned int crc = 0;
  for (int i = 0; i < n; i++) {
    int top = (crc >> 14) & 1;
    crc = (crc << 1) & 0x7FFF;
    if (top ^ buf[i]) crc ^= 0x4599;
  }
  return crc & 0x7FFF;
}

static unsigned char rawbits[MAXBITS];
static unsigned char dbit[MAXBITS];

int main(void) {
  PIN_OUT = 0;
  PIN_OE = 0;

  /* wait for the SOF (bus dominant while idle) */
  while (bus_level() == 1) {
  }
  delay_cycles(RX_SAMPLE);
  if (bus_level() != 0) {
    results[0] = 0xBAD;
    HALT = 0;
    return 0;
  }

  /* constant-time sampling: one bit per RX_BIT cycles */
  rawbits[0] = 0;
  for (int i = 1; i < MAXBITS; i++) {
    delay_cycles(RX_BIT);
    rawbits[i] = (unsigned char)bus_level();
  }

  /* de-stuff */
  int nd = 0;
  int last = -1, run = 0, skip = 0;
  for (int i = 0; i < MAXBITS; i++) {
    int b = rawbits[i];
    if (skip) {
      skip = 0;
      last = b;
      run = 1;
      continue;
    }
    dbit[nd++] = (unsigned char)b;
    if (b == last) {
      run++;
    } else {
      last = b;
      run = 1;
    }
    if (run == 5) skip = 1;
  }

  unsigned int id = 0;
  for (int i = 1; i <= 11; i++) id = (id << 1) | dbit[i];
  int dlc = (dbit[15] << 3) | (dbit[16] << 2) | (dbit[17] << 1) | dbit[18];
  int frame_len = 19 + 8 * dlc + 15;
  unsigned int data = 0;
  for (int i = 0; i < 8 * dlc; i++) data = (data << 1) | dbit[19 + i];
  unsigned int got = 0;
  for (int i = 0; i < 15; i++) got = (got << 1) | dbit[frame_len - 15 + i];
  unsigned int calc = crc15(dbit, frame_len - 15);

  results[0] = id;
  results[1] = (unsigned int)dlc;
  results[2] = data;
  results[3] = (got == calc) ? 1 : 0;
  results[4] = (unsigned int)frame_len;
  HALT = 0;
  return 0;
}
