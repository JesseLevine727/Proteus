/* Proteus CAN 2.0A firmware node.

   Transmits a standard data frame on an open-drain CAN_TX pin (uio[0]),
   with bit stuffing and CRC-15, samples the bus for arbitration and ACK, and
   records the outcome in data RAM.

   CAN_TX = uio[0] (dominant = drive low, recessive = release)
   CAN_RX = ui_in[0] */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)
#define RESULT ((volatile unsigned int *)0x10000000u)

#define CAN_TX_OE 0x10000u
#define CAN_RX_BIT 0x100u

/* Bit timing in core cycles. */
#define BIT_TIME 200
#define SAMPLE_AT 150

static inline void delay_cycles(unsigned int n) {
  __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" : : "r"(n));
}

static inline int bus_level(void) { return (PIN_IN & CAN_RX_BIT) ? 1 : 0; }

static inline void drive(int recessive) {
  if (recessive) {
    PIN_OE &= ~CAN_TX_OE;
  } else {
    PIN_OE |= CAN_TX_OE;
  }
}

/* transmit one bit; return the bus level at the sample point */
static int send_bit(int b) {
  drive(b);
  delay_cycles(SAMPLE_AT);
  int bus = bus_level();
  delay_cycles(BIT_TIME - SAMPLE_AT);
  return bus;
}

/* raw frame bits from SOF through the data field */
static int build_frame(unsigned int id, const unsigned char *data, int len, int *buf) {
  int n = 0;
  buf[n++] = 0; /* SOF */
  for (int i = 10; i >= 0; i--) buf[n++] = (id >> i) & 1;
  buf[n++] = 0; /* RTR */
  buf[n++] = 0; /* IDE */
  buf[n++] = 0; /* r0 */
  for (int i = 3; i >= 0; i--) buf[n++] = (len >> i) & 1; /* DLC */
  for (int i = 0; i < len; i++)
    for (int b = 7; b >= 0; b--) buf[n++] = (data[i] >> b) & 1;
  return n;
}

/* CRC-15 (poly 0x4599) over the raw bits */
static unsigned int crc15(const int *buf, int n) {
  unsigned int crc = 0;
  for (int i = 0; i < n; i++) {
    int top = (crc >> 14) & 1;
    crc = (crc << 1) & 0x7FFF;
    if (top ^ buf[i]) crc ^= 0x4599;
  }
  return crc & 0x7FFF;
}

/* transmit bits with bit stuffing; returns 1 if no arbitration was lost */
static int send_stuffed(const int *buf, int n) {
  int last = buf[0];
  int run = 0;
  for (int i = 0; i < n; i++) {
    int b = buf[i];
    if (b == last) {
      run++;
    } else {
      last = b;
      run = 1;
    }
    int bus = send_bit(b);
    if (b != bus) return 0; /* arbitration lost or bit error */
    if (run == 5) {
      int stuff = !b;
      bus = send_bit(stuff);
      if (stuff != bus) return 0;
      last = stuff;
      run = 1;
    }
  }
  return 1;
}

int main(void) {
  PIN_OUT = 0; /* we only drive low */
  PIN_OE = 0;  /* release */
  delay_cycles(100);

  static int raw[128];
  unsigned char data[3] = {0x11, 0x22, 0x33};
  int n = build_frame(0x123u, data, 3, raw);
  unsigned int crc = crc15(raw, n);
  for (int i = 14; i >= 0; i--) raw[n++] = (crc >> i) & 1;

  int ok = send_stuffed(raw, n);

  /* CRC delimiter, ACK slot, ACK delimiter, EOF, IFS */
  send_bit(1);
  int ack = send_bit(1); /* recessive; dominant means a receiver ACKed */
  send_bit(1);
  for (int i = 0; i < 7; i++) send_bit(1);
  for (int i = 0; i < 3; i++) send_bit(1);

  RESULT[0] = (unsigned int)ok;
  RESULT[1] = crc;
  RESULT[2] = (unsigned int)n;
  RESULT[3] = (unsigned int)(ack == 0); /* 1 = ACK received */
  HALT = 0;
  return 0;
}
