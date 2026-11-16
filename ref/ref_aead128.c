/* ref_aead128.c - official Ascon-AEAD128, entry points renamed (see ascon_ref.h) */
#define crypto_aead_encrypt ascon_ref_aead_encrypt
#define crypto_aead_decrypt ascon_ref_aead_decrypt
#include "ascon-c/asconaead128/aead.c"
