/* Proteus I2C slave, address 0x50.

   Polls SCL/SDA, detects START, receives the address byte and, if addressed,
   ACKs it. A write transaction receives one data byte and ACKs it; a read
   transaction clocks out one byte and samples the master's ACK/NACK. The
   results are written to a fixed .result section.

   SDA = uio[0] (open-drain: drive low / release), SCL = uio[1] (input). */

#define PINS 0x20000000u
#define PIN_OUT (*(volatile unsigned int *)(PINS + 0))
#define PIN_OE (*(volatile unsigned int *)(PINS + 4))
#define PIN_IN (*(volatile unsigned int *)(PINS + 8))
#define HALT (*(volatile unsigned int *)0x70000000u)

#define SDA_OE 0x10000u
#define SDA_IN 0x10000u
#define SCL_IN 0x20000u
#define MY_ADDR 0x50

static volatile unsigned int results[64] __attribute__((section(".result"), used));

static int sda(void) { return (PIN_IN & SDA_IN) ? 1 : 0; }
static int scl(void) { return (PIN_IN & SCL_IN) ? 1 : 0; }
static void sda_low(void) { PIN_OE |= SDA_OE; }
static void sda_rel(void) { PIN_OE &= ~SDA_OE; }
static void wait_scl_high(void) {
  while (!scl()) {
  }
}
static void wait_scl_low(void) {
  while (scl()) {
  }
}

static int recv_byte(void) {
  int d = 0;
  for (int i = 0; i < 8; i++) {
    wait_scl_high();
    d = (d << 1) | sda();
    wait_scl_low();
  }
  return d;
}

static void send_ack(void) {
  sda_low();
  wait_scl_high();
  wait_scl_low();
  sda_rel();
}

static void send_byte(int b) {
  for (int i = 0; i < 8; i++) {
    wait_scl_low();
    if ((b >> (7 - i)) & 1) {
      sda_rel();
    } else {
      sda_low();
    }
    wait_scl_high();
  }
  /* hold the last bit until the master lowers SCL, then release for the
     ACK/NACK clock */
  wait_scl_low();
  sda_rel();
}

int main(void) {
  PIN_OUT = 0;
  PIN_OE = 0;

  /* wait for idle, then a START (SDA falls while SCL high) */
  while (!(scl() && sda())) {
  }
  while (sda()) {
  }
  wait_scl_low();

  int addr_byte = recv_byte();
  int rw = addr_byte & 1;
  int got = -1;
  int ack_from_master = -1;

  if ((addr_byte >> 1) == MY_ADDR) {
    send_ack();
    if (rw) {
      send_byte(0x42);
      wait_scl_high();
      ack_from_master = sda(); /* 0 = ACK from master */
      wait_scl_low();
    } else {
      got = recv_byte();
      send_ack();
    }
  }

  results[0] = (unsigned int)got;
  results[1] = (unsigned int)rw;
  results[2] = (unsigned int)addr_byte;
  results[3] = (unsigned int)ack_from_master;
  HALT = 0;
  return 0;
}
