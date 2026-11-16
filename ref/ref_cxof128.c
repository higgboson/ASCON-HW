/* ref_cxof128.c - official Ascon-CXOF128, entry points renamed (see ascon_ref.h) */
#define crypto_cxof ascon_ref_cxof128
#define crypto_hash ascon_ref_cxof128_64
#include "ascon-c/asconcxof128/hash.c"
