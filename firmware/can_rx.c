/* Proteus CAN 2.0A firmware receiver.

   The timing-critical sampling, de-stuffing and ACK loop is hand-written in
   assembly (firmware/can_rx_asm.S) so the bit period is exactly constant.
   This file decodes the de-stuffed bits and checks CRC-15.

   CAN_RX = ui_in[0]; CAN_TX = uio[0] (driven by the assembly ACK).

   The assembly is needed because the C compiler hoists the de-stuff out of
   the sampling loop, which makes the sample point drift and breaks both the
   decode and the ACK timing. */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define MAXBITS 100

static volatile unsigned int results[64] __attribute__((section(".result"), used));

/* filled by can_sample() in can_rx_asm.S */
unsigned char dbit[MAXBITS];

/* returns the de-stuffed frame length (SOF..CRC), or -1 on a bad SOF */
extern int can_sample(void);

static unsigned int crc15(const unsigned char *buf, int n) {
  unsigned int crc = 0;
  for (int i = 0; i < n; i++) {
    int top = (crc >> 14) & 1;
    crc = (crc << 1) & 0x7FFF;
    if (top ^ buf[i]) crc ^= 0x4599;
  }
  return crc & 0x7FFF;
}

int main(void) {
  PIN_OUT = 0; /* only ever drive low */
  PIN_OE = 0;

  int frame_len = can_sample();
  if (frame_len < 0) {
    results[0] = 0xBAD;
    HALT = 0;
    return 0;
  }

  unsigned int id = 0;
  for (int i = 1; i <= 11; i++) id = (id << 1) | dbit[i];
  int dlc = (dbit[15] << 3) | (dbit[16] << 2) | (dbit[17] << 1) | dbit[18];
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
