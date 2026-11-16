#!/usr/bin/env python3
"""inject_bug.py - plant a known bug in the RTL, to prove the testbench can catch it

    python3 inject_bug.py list          show the bugs
    python3 inject_bug.py <name>        plant one (the clean file is kept as ascon_core.v.orig)
    python3 inject_bug.py restore       put the clean file back

Then run any test (UVM on Xcelium / Verilator, or the KAT testbench). It must FAIL.
A testbench that passes with a bug planted is not checking what you think it checks.
"""
import os
import shutil
import sys

RTL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl", "ascon_core.v")
ORIG = RTL + ".orig"

# name: (what it is, who should catch it, text to find, text to put instead)
BUGS = {
    "pad80": (
        "padding byte 0x80 instead of 0x01 (what the older Ascon v1.2 documents suggest)",
        "scoreboard: wrong output whenever a block is not full",
        "padv[8*b +: 8] = (b[4:0] == n) ? 8'h01 : 8'h00;",
        "padv[8*b +: 8] = (b[4:0] == n) ? 8'h80 : 8'h00;",
    ),
    "six_rounds": (
        "data blocks use 6 rounds, as the old Ascon-128 did, instead of 8",
        "scoreboard: wrong output and wrong run length on anything longer than one block",
        "wire [3:0] pb_first = aead ? 4'd4 : 4'd0;",
        "wire [3:0] pb_first = aead ? 4'd6 : 4'd0;",
    ),
    "dec_absorb": (
        "decrypt absorbs the plaintext instead of the ciphertext",
        "scoreboard: genuine messages are rejected, plaintext wrong after the first block",
        "wire [127:0] absorb = (dec && st == S_MSG) ? dout_w : (din_data & mask);",
        "wire [127:0] absorb = din_data & mask;",
    ),
    "skip_dsep": (
        "the domain-separation bit is forgotten when there is no associated data",
        "scoreboard, but only on operations with empty associated data (why corners matter)",
        "                x4 <= x4 ^ DSEP;\n                st <= S_MSG;",
        "                st <= S_MSG;",
    ),
    "tag_leak": (
        "decrypt shows the tag it computed (an attacker could then forge any message)",
        "assertion a_dec_hides_tag, and the scoreboard's tag compare",
        "tag    <= dec ? 128'b0 : {t1, t0};",
        "tag    <= {t1, t0};",
    ),
    "no_wipe": (
        "state and key are left in the registers after an AEAD operation",
        "assertion a_wiped ONLY: every result is still right, so a scoreboard cannot see it",
        "                done   <= 1'b1;\n                {x0, x1, x2, x3, x4} <= 320'b0;\n"
        "                {k1, k0} <= 128'b0;\n                st     <= S_IDLE;",
        "                done   <= 1'b1;\n                st     <= S_IDLE;",
    ),
}


def restore():
    if os.path.exists(ORIG):
        shutil.move(ORIG, RTL)
        # A move keeps the old file date. Simulators that decide whether to recompile by
        # comparing dates (Xcelium does) would then keep running the buggy snapshot.
        os.utime(RTL, None)
        print("clean RTL restored")
    else:
        print("nothing to restore")


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "list":
        for name, (what, who, _, _) in BUGS.items():
            print(f"{name:11s} {what}\n{'':11s} caught by: {who}")
        return 0
    if cmd == "restore":
        restore()
        return 0
    if cmd not in BUGS:
        print(f"unknown bug '{cmd}' (try: list)")
        return 1

    if os.path.exists(ORIG):            # always start from the clean file
        shutil.copy(ORIG, RTL)
    else:
        shutil.copy(RTL, ORIG)
    what, who, old, new = BUGS[cmd]
    text = open(RTL).read()
    if text.count(old) != 1:
        print("the RTL has changed: the line this bug replaces was not found exactly once")
        restore()
        return 1
    open(RTL, "w").write(text.replace(old, new))
    print(f"planted: {what}\nexpect : {who}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
