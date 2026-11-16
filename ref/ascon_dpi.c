/* ascon_dpi.c - the reference model as the UVM scoreboard calls it (SystemVerilog DPI-C)
 *
 * Arrays arrive as plain byte pointers (SystemVerilog "byte unsigned x [N]").
 * The SystemVerilog side of these functions is verif/uvm/env_lib/ascon_ref_dpi.svh. */

#include <string.h>
#include "ascon_ref.h"

#define MAXB 256

void ascon_dpi_aead_enc(const unsigned char *key, const unsigned char *nonce,
                        const unsigned char *ad, int adlen,
                        const unsigned char *m, int mlen,
                        unsigned char *c, unsigned char *tag)
{
    unsigned char buf[MAXB + 16];
    unsigned long long clen;

    ascon_ref_aead_encrypt(buf, &clen, m, mlen, ad, adlen, 0, nonce, key);
    memcpy(c, buf, mlen);
    memcpy(tag, buf + mlen, 16);
}

/* returns 1 if the tag is right. m is filled in either way, as the hardware does. */
int ascon_dpi_aead_dec(const unsigned char *key, const unsigned char *nonce,
                       const unsigned char *ad, int adlen,
                       const unsigned char *c, int clen, const unsigned char *tag,
                       unsigned char *m)
{
    unsigned char buf[MAXB + 16];
    unsigned long long mlen;

    memcpy(buf, c, clen);
    memcpy(buf + clen, tag, 16);
    return ascon_ref_aead_decrypt(m, &mlen, 0, buf, clen + 16, ad, adlen, nonce, key) == 0;
}

/* mode: 2 = Hash256 (outlen ignored, 32 bytes), 3 = XOF128, 4 = CXOF128 (z = customization).
 * Returns the number of output bytes, or -1 if the reference cannot do the request. */
int ascon_dpi_hash(int mode, const unsigned char *z, int zlen,
                   const unsigned char *m, int mlen,
                   unsigned char *out, int outlen)
{
    unsigned char buf[64];

    switch (mode) {
    case 2:
        ascon_ref_hash256(out, m, mlen);
        return 32;
    case 3:
        if (outlen > 64) return -1;
        ascon_ref_xof128_64(buf, m, mlen);
        memcpy(out, buf, outlen);
        return outlen;
    case 4:
        ascon_ref_cxof128(out, outlen, m, mlen, z, zlen);
        return outlen;
    default:
        return -1;
    }
}
