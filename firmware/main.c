/* Proteus C firmware: print a message over the memory-mapped debug UART. */

#define UART_TX ((volatile unsigned int *)0x60000000u)
#define UART_STATUS ((volatile unsigned int *)0x60000008u)

static void putc_(int c) {
  while (*UART_STATUS & 1u) {
    /* wait while the transmitter is busy */
  }
  *UART_TX = (unsigned int)c & 0xffu;
}

static void print(const char *s) {
  while (*s) {
    putc_(*s++);
  }
}

static const char msg[] = "Hello from Proteus C!\n";

int main(void) {
  print(msg);
  return 0;
}
