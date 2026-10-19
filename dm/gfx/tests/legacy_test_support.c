// Standalone graphics tests omit the host entry and NVN dispatch layer.
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
__attribute__((weak)) uint64_t nvn_new_serial(void) { static _Atomic uint64_t n = 1000000; return atomic_fetch_add(&n, 1); }
// These tests execute on a normal host stack, outside guest address space.
int dm_guest_as_contains(uintptr_t p) { (void)p; return 0; }
__attribute__((weak)) void die(const char *fmt, ...) { (void)fmt; abort(); }
