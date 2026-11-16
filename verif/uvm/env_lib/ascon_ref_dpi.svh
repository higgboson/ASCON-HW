// ascon_ref_dpi.svh - the C reference model (ref/ascon_dpi.c), seen from SystemVerilog
//
// Behind these functions is the Ascon team's own reference code, unmodified (ref/ascon-c/).

import "DPI-C" function void ascon_dpi_aead_enc(
    input  byte unsigned key [16],           input byte unsigned nonce [16],
    input  byte unsigned ad  [`ASCON_MAXB],  input int adlen,
    input  byte unsigned m   [`ASCON_MAXB],  input int mlen,
    output byte unsigned c   [`ASCON_MAXB],  output byte unsigned tag [16]);

// returns 1 if the tag is right; m is filled in either way
import "DPI-C" function int ascon_dpi_aead_dec(
    input  byte unsigned key [16],           input byte unsigned nonce [16],
    input  byte unsigned ad  [`ASCON_MAXB],  input int adlen,
    input  byte unsigned c   [`ASCON_MAXB],  input int clen,
    input  byte unsigned tag [16],
    output byte unsigned m   [`ASCON_MAXB]);

// mode 2 = Hash256, 3 = XOF128 (up to 64 bytes), 4 = CXOF128 (z = customization string).
// Returns the number of output bytes, or -1 if the reference cannot do the request.
import "DPI-C" function int ascon_dpi_hash(
    input  int mode,
    input  byte unsigned z   [`ASCON_MAXB],  input int zlen,
    input  byte unsigned m   [`ASCON_MAXB],  input int mlen,
    output byte unsigned out [`ASCON_MAXB],  input int outlen);
