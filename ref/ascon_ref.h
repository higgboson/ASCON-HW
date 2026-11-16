/* ascon_ref.h - the official reference code (ascon-c/), under names that can live together
 *
 * Each ref_*.c file compiles one of the four official implementations and renames its
 * entry point, because they all call it crypto_hash / crypto_aead_encrypt. */

#ifndef ASCON_REF_H
#define ASCON_REF_H

/* c gets the ciphertext followed by the 16-byte tag: *clen = mlen + 16 */
int ascon_ref_aead_encrypt(unsigned char *c, unsigned long long *clen,
                           const unsigned char *m, unsigned long long mlen,
                           const unsigned char *ad, unsigned long long adlen,
                           const unsigned char *nsec, const unsigned char *npub,
                           const unsigned char *k);

/* c is ciphertext followed by the tag. Returns 0 if the tag is right, -1 if not. */
int ascon_ref_aead_decrypt(unsigned char *m, unsigned long long *mlen,
                           unsigned char *nsec, const unsigned char *c,
                           unsigned long long clen, const unsigned char *ad,
                           unsigned long long adlen, const unsigned char *npub,
                           const unsigned char *k);

/* 32-byte hash */
int ascon_ref_hash256(unsigned char *out, const unsigned char *in, unsigned long long inlen);

/* the reference XOF128 always gives 64 bytes; a shorter output is the first bytes of it */
int ascon_ref_xof128_64(unsigned char *out, const unsigned char *in, unsigned long long inlen);

int ascon_ref_cxof128(unsigned char *out, unsigned long long outlen,
                      const unsigned char *in, unsigned long long inlen,
                      const unsigned char *cs, unsigned long long cslen);

#endif
