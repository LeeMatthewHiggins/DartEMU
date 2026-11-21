#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define ROUNDS 3
#define CRC_BYTES (1 << 16)
#define FIB_N 24
#define FIB_REPEATS 4
#define SIEVE_SIZE (1 << 18)
#define SORT_COUNT (1 << 13)
#define MANDEL_W 64
#define MANDEL_H 48
#define MANDEL_LIMIT 256

static unsigned char crc_buf[CRC_BYTES];
static char sieve[SIEVE_SIZE];
static int sort_buf[SORT_COUNT];

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static unsigned crc32(void) {
  unsigned c = 0xFFFFFFFF;
  for (int i = 0; i < CRC_BYTES; i++) {
    c ^= crc_buf[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320 & -(c & 1));
  }
  return ~c;
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static unsigned fib_bench(void) {
  unsigned r = 0;
  for (int i = 0; i < FIB_REPEATS; i++) r += fib(FIB_N);
  return r;
}

static unsigned sieve_bench(void) {
  unsigned primes = 0;
  memset(sieve, 1, sizeof sieve);
  for (int p = 2; p * p < SIEVE_SIZE; p++)
    if (sieve[p])
      for (int m = p * p; m < SIEVE_SIZE; m += p) sieve[m] = 0;
  for (int p = 2; p < SIEVE_SIZE; p++) primes += sieve[p];
  return primes;
}

static int compare(const void *a, const void *b) {
  int x = *(const int *)a, y = *(const int *)b;
  return (x > y) - (x < y);
}

static unsigned sort_bench(void) {
  unsigned seed = 12345;
  for (int i = 0; i < SORT_COUNT; i++)
    sort_buf[i] = (int)(seed = seed * 1103515245 + 12345);
  qsort(sort_buf, SORT_COUNT, sizeof *sort_buf, compare);
  return (unsigned)sort_buf[SORT_COUNT / 2];
}

static unsigned mandel_bench(void) {
  unsigned total = 0;
  for (int y = 0; y < MANDEL_H; y++)
    for (int x = 0; x < MANDEL_W; x++) {
      double cr = -2.2 + 3.0 * x / MANDEL_W, ci = -1.2 + 2.4 * y / MANDEL_H;
      double a = 0, b = 0;
      int n = 0;
      while (a * a + b * b < 4 && n < MANDEL_LIMIT) {
        double t = a * a - b * b + cr;
        b = 2 * a * b + ci;
        a = t;
        n++;
      }
      total += n;
    }
  return total;
}

struct kernel {
  const char *name;
  const char *stresses;
  unsigned (*run)(void);
};

static const struct kernel kernels[] = {
    {"crc32", "integer, bit ops", crc32},
    {"fib", "calls, stack", fib_bench},
    {"sieve", "memory, branches", sieve_bench},
    {"qsort", "libc, indirect calls", sort_bench},
    {"mandel", "double precision", mandel_bench},
};

int main(int argc, char **argv) {
  int count = sizeof kernels / sizeof *kernels;
  int only = argc > 1 ? atoi(argv[1]) : -1;
  double total = 0;
  for (int i = 0; i < CRC_BYTES; i++) crc_buf[i] = (unsigned char)(i * 31);

  printf("%-7s %9s %11s  %s\n", "test", "best ms", "checksum", "stresses");
  for (int k = 0; k < count; k++) {
    if (only >= 0 && k != only) continue;
    double best = 1e9;
    unsigned sum = 0;
    for (int r = 0; r < ROUNDS; r++) {
      double start = now();
      sum = kernels[k].run();
      double ms = (now() - start) * 1000;
      if (ms < best) best = ms;
    }
    total += best;
    printf("%-7s %9.1f %11u  %s\n", kernels[k].name, best, sum,
           kernels[k].stresses);
  }
  printf("%-7s %9.1f  (best of %d per test; lower is better)\n", "total",
         total, ROUNDS);
  return 0;
}
