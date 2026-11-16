# Official known-answer tests

From the Ascon team's reference package (<https://github.com/ascon/ascon-c>, CC0, commit
`446347f`), unmodified apart from the file names:

| File | Algorithm | Vectors | Original name |
|---|---|---|---|
| `aead128.txt` | Ascon-AEAD128 | 1,089 | `crypto_aead/asconaead128/LWC_AEAD_KAT_128_128.txt` |
| `hash256.txt` | Ascon-Hash256 | 1,025 | `crypto_hash/asconhash256/LWC_HASH_KAT_128_256.txt` |
| `xof128.txt` | Ascon-XOF128 | 1,025 | `crypto_hash/asconxof128/LWC_XOF_KAT_128_512.txt` |
| `cxof128.txt` | Ascon-CXOF128 | 1,089 | `crypto_cxof/asconcxof128/LWC_CXOF_KAT_128_512.txt` |

`verif/gen_vectors.py` flattens them into one file the testbenches read.
