# Official Ascon reference code (unmodified)

Source: https://github.com/ascon/ascon-c, commit 446347f (28 Jan 2026), the `ref`
implementations of the four NIST SP 800-232 algorithms. Licence: CC0 (see LICENSE).

| Folder | Algorithm | From |
|---|---|---|
| `asconaead128/` | Ascon-AEAD128 | `crypto_aead/asconaead128/ref` |
| `asconhash256/` | Ascon-Hash256 | `crypto_hash/asconhash256/ref` |
| `asconxof128/`  | Ascon-XOF128 (64 output bytes) | `crypto_hash/asconxof128/ref` |
| `asconcxof128/` | Ascon-CXOF128 (any output length) | `crypto_cxof/asconcxof128/ref` |

`crypto_aead.h` / `crypto_hash.h` are the prototypes from the package's `tests/` folder.
Nothing here was edited: this is the judge the hardware is compared against, so it has to
be the authors' code, not ours. `../ascon_ref.c` wraps it for the testbench.
