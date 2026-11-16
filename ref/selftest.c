/* selftest.c - checks that the reference model gives the first official test vectors
 *
 *     gcc -O2 -o selftest selftest.c ascon_dpi.c ref_*.c && ./selftest */

#include <stdio.h>
#include <string.h>

void ascon_dpi_aead_enc(const unsigned char *, const unsigned char *, const unsigned char *, int,
                        const unsigned char *, int, unsigned char *, unsigned char *);
int  ascon_dpi_aead_dec(const unsigned char *, const unsigned char *, const unsigned char *, int,
                        const unsigned char *, int, const unsigned char *, unsigned char *);
int  ascon_dpi_hash(int, const unsigned char *, int, const unsigned char *, int,
                    unsigned char *, int);

static int check(const char *name, const unsigned char *got, const char *hex, int n)
{
    char s[2 * 64 + 1];
    for (int i = 0; i < n; i++) sprintf(s + 2 * i, "%02X", got[i]);
    int ok = strncmp(s, hex, 2 * n) == 0;
    printf("%-22s %s\n", name, ok ? "ok" : "WRONG");
    return !ok;
}

int main(void)
{
    unsigned char key[16], nonce[16], ad[256], m[256], c[256], tag[16], out[256], back[256];
    int bad = 0;

    for (int i = 0; i < 16; i++) { key[i] = i; nonce[i] = 0x10 + i; }
    for (int i = 0; i < 256; i++) { ad[i] = 0x30 + i; m[i] = 0x20 + i; }

    /* kat/aead128.txt, Count = 1 and Count = 2 */
    ascon_dpi_aead_enc(key, nonce, ad, 0, m, 0, c, tag);
    bad += check("AEAD128 empty", tag, "4F9C278211BEC9316BF68F46EE8B2EC6", 16);
    ascon_dpi_aead_enc(key, nonce, ad, 1, m, 0, c, tag);
    bad += check("AEAD128 1-byte AD", tag, "CCCB674FE18A09A285D6AB11B35675C0", 16);

    /* encrypt then decrypt, then a tampered tag */
    ascon_dpi_aead_enc(key, nonce, ad, 23, m, 41, c, tag);
    int ok = ascon_dpi_aead_dec(key, nonce, ad, 23, c, 41, tag, back);
    printf("%-22s %s\n", "AEAD128 round trip", (ok && !memcmp(back, m, 41)) ? "ok" : "WRONG");
    bad += !(ok && !memcmp(back, m, 41));
    tag[5] ^= 0x40;
    ok = ascon_dpi_aead_dec(key, nonce, ad, 23, c, 41, tag, back);
    printf("%-22s %s\n", "AEAD128 bad tag", !ok ? "ok" : "WRONG");
    bad += ok;

    /* Count = 1 of the hash, XOF and CXOF files (empty message) */
    ascon_dpi_hash(2, 0, 0, m, 0, out, 32);
    bad += check("Hash256 empty", out,
                 "0B3BE5850F2F6B98CAF29F8FDEA89B64A1FA70AA249B8F839BD53BAA304D92B2", 32);
    ascon_dpi_hash(3, 0, 0, m, 0, out, 16);
    bad += check("XOF128 empty", out, "473D5E6164F58B39DFD84AACDB8AE42E", 16);
    ascon_dpi_hash(4, m, 0, m, 0, out, 16);
    bad += check("CXOF128 empty", out, "4F50159EF70BB3DAD8807E034EAEBD44", 16);

    printf(bad ? "SELFTEST FAILED\n" : "SELFTEST PASSED\n");
    return bad;
}
