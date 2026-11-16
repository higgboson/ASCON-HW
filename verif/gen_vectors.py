#!/usr/bin/env python3
"""gen_vectors.py - turn the official known-answer test files (kat/*.txt) into one flat
file the Verilog testbench can read with $fscanf.

    python3 gen_vectors.py ../kat vectors.txt

One test per line:
    mode adlen mlen outlen key nonce ad msg out tag
mode: 0 = AEAD (the testbench runs it as encrypt, decrypt and a tampered decrypt),
      2 = Hash256, 3 = XOF128, 4 = CXOF128 (ad = the customization string)
Lengths are in bytes. Hex fields are written first byte first; an empty field is "0".
"""
import sys


def read_kat(path):
    tests, cur = [], {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                if cur:
                    tests.append(cur)
                    cur = {}
                continue
            name, _, value = line.partition("=")
            cur[name.strip()] = value.strip()
    if cur:
        tests.append(cur)
    return tests


def h(s):
    return s if s else "0"


def main(kat_dir, out_path):
    lines = []
    zero = "0"

    for t in read_kat(f"{kat_dir}/aead128.txt"):
        ad, pt, ct = t["AD"], t["PT"], t["CT"]
        body, tag = ct[:-32], ct[-32:]
        assert len(body) == len(pt)
        lines.append(f"0 {len(ad)//2} {len(pt)//2} {len(pt)//2} {t['Key']} {t['Nonce']} "
                     f"{h(ad)} {h(pt)} {h(body)} {tag}")

    for mode, name in ((2, "hash256"), (3, "xof128")):
        for t in read_kat(f"{kat_dir}/{name}.txt"):
            msg, md = t["Msg"], t["MD"]
            lines.append(f"{mode} 0 {len(msg)//2} {len(md)//2} {zero} {zero} "
                         f"{zero} {h(msg)} {md} {zero}")

    for t in read_kat(f"{kat_dir}/cxof128.txt"):
        msg, z, md = t["Msg"], t["Z"], t["MD"]
        lines.append(f"4 {len(z)//2} {len(msg)//2} {len(md)//2} {zero} {zero} "
                     f"{h(z)} {h(msg)} {md} {zero}")

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(lines)} tests written to {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
