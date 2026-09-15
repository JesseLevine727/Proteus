/* Proteus CAN error handling.

   Transmits a standard frame several times with no receiver ACKing, so each
   attempt raises an ACK error: the transmit error counter (TEC) grows by 8
   and an error frame (6 dominant bits) is emitted. The final TEC and the
   derived error state are reported, along with the state thresholds.

   Error state: 0 = error-active, 1 = error-passive (TEC/REC >= 128),
   2 = bus-off (TEC >= 256). */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define CAN_TX_OE 0x10000u
#define CAN_RX_BIT 0x100u

#define BIT_TIME 100
#define SAMPLE_AT 75
#define ATTEMPTS 4

static volatile unsigned int results[64] __attribute__((section(".result"), used));

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

static int send_bit(int b) {
  drive(b);
  delay_cycles(SAMPLE_AT);
  int bus = bus_level();
  delay_cycles(BIT_TIME - SAMPLE_AT);
  return bus;
}

static int build_frame(unsigned int id, const unsigned char *data, int len, int *buf) {
  int n = 0;
  buf[n++] = 0;
  for (int i = 10; i >= 0; i--) buf[n++] = (id >> i) & 1;
  buf[n++] = 0;
  buf[n++] = 0;
  buf[n++] = 0;
  for (int i = 3; i >= 0; i--) buf[n++] = (len >> i) & 1;
  for (int i = 0; i < len; i++)
    for (int b = 7; b >= 0; b--) buf[n++] = (data[i] >> b) & 1;
  return n;
}

static unsigned int crc15(const int *buf, int n) {
  unsigned int crc = 0;
  for (int i = 0; i < n; i++) {
    int top = (crc >> 14) & 1;
    crc = (crc << 1) & 0x7FFF;
    if (top ^ buf[i]) crc ^= 0x4599;
  }
  return crc & 0x7FFF;
}

static int send_stuffed(const int *buf, int n) {
  int last = buf[0], run = 0;
  for (int i = 0; i < n; i++) {
    int b = buf[i];
    if (b == last) {
      run++;
    } else {
      last = b;
      run = 1;
    }
    int bus = send_bit(b);
    if (b != bus) return 0;
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

/* returns 1 if the frame was acknowledged */
static int transmit(void) {
  static int raw[128];
  unsigned char data[1] = {0};
  int n = build_frame(0x123u, data, 0, raw);
  unsigned int crc = crc15(raw, n);
  for (int i = 14; i >= 0; i--) raw[n++] = (crc >> i) & 1;
  int ok = send_stuffed(raw, n);
  send_bit(1);
  int ack = send_bit(1);
  send_bit(1);
  for (int i = 0; i < 7; i++) send_bit(1);
  for (int i = 0; i < 3; i++) send_bit(1);
  return ok && ack == 0;
}

/* active error frame: 6 dominant bits then an error delimiter */
static void error_frame(void) {
  for (int i = 0; i < 6; i++) send_bit(0);
  for (int i = 0; i < 8; i++) send_bit(1);
}

static int error_state(int tec) { return tec >= 256 ? 2 : (tec >= 128 ? 1 : 0); }

int main(void) {
  PIN_OUT = 0;
  PIN_OE = 0;
  delay_cycles(50);

  int tec = 0;
  int errors = 0;
  for (int k = 0; k < ATTEMPTS; k++) {
    if (transmit()) {
      if (tec > 0) tec -= 1;
    } else {
      tec += 8;
      errors++;
      error_frame();
    }
  }

  results[0] = (unsigned int)tec;
  results[1] = (unsigned int)error_state(tec);
  results[2] = (unsigned int)error_state(128);
  results[3] = (unsigned int)error_state(256);
  results[4] = (unsigned int)error_state(127);
  results[5] = (unsigned int)errors;
  HALT = 0;
  return 0;
}
