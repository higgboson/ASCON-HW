# Learning guide: understand every line of this project

Read this with the files open. Each section names the file it explains. Nothing here needs
cryptography background; it needs digital design and a bit of C.

The last section is a list of questions an interviewer or professor is likely to ask. If you
can answer them without looking, the project is yours.

## 1. The problem: what "authenticated encryption" is for

Two devices share a secret **key**. One sends the other a message over a wire an attacker
can read and change. The sender wants two things:

- **Secrecy**: the attacker cannot read the message.
- **Integrity**: if the attacker changes even one bit, the receiver notices and throws the
  message away.

Encryption alone gives only the first. An algorithm that gives both is called **AEAD**,
authenticated encryption with associated data. Its inputs and outputs:

| Name | Size here | What it is |
|---|---|---|
| key | 16 bytes | the shared secret |
| nonce | 16 bytes | a number used once. Not secret, but **never repeated with the same key** |
| associated data (AD) | any | sent in the clear but protected against changes (a packet header, an address) |
| plaintext | any | the message |
| ciphertext | same as plaintext | the encrypted message |
| tag | 16 bytes | a checksum only someone with the key can compute |

The receiver recomputes the tag. If it differs from the one received, the message was
changed (or the key, nonce or AD is wrong) and the plaintext must not be used.

Why the nonce matters: the cipher is deterministic. Same key, nonce and message give the
same ciphertext. With a repeated nonce an attacker who XORs two ciphertexts gets the XOR of
the two plaintexts. The hardware cannot enforce uniqueness; the software that calls it must
(a counter is enough).

**Ascon** is the AEAD (and hash) family NIST standardised in August 2025 as SP 800-232 for
small devices. This project implements all four functions of the standard:
Ascon-AEAD128, Ascon-Hash256, Ascon-XOF128, Ascon-CXOF128.

## 2. The sponge: one idea behind all four functions

Keep a 320-bit **state**. Repeat:

1. XOR the next block of input into the first part of the state (the **rate**: 16 bytes for
   AEAD, 8 bytes for the hash functions).
2. Scramble the whole state with a fixed function, the **permutation**.

The rest of the state (the **capacity**) is never touched directly by the input and never
shown in the output. That hidden part is what makes it secure.

- To **hash**: absorb the message block by block, then read the rate out as the hash,
  permuting between output blocks.
- To **encrypt**: start the state from key and nonce. For each plaintext block, the
  ciphertext is `rate XOR plaintext`, and that ciphertext stays in the rate. At the end,
  part of the state (mixed with the key) is the tag.

So one datapath does everything: a 320-bit register, an XOR at the front, the permutation.
Only the start value, the rate and the number of rounds change. That is why
`rtl/ascon_core.v` has one state machine for five modes.

## 3. The permutation (`rtl/ascon_round.v`)

The state is five 64-bit words `x0..x4`. The permutation is one **round** repeated 12 times
(or 8 times, using the last 8 of the 12, for AEAD data blocks). One round has three steps:

1. **Constant**: XOR an 8-bit number into `x2`. It is different in each round
   (`f0, e1, d2, ... 4b`: high nibble counts down, low nibble counts up), so the rounds are
   not identical. Without it, patterns could survive from round to round.
2. **S-box** (substitution): think of the five words stacked as 5 rows of 64 bits. Each of
   the 64 columns is a 5-bit number, and each is replaced by another 5-bit number through
   the same small function. This is the only non-linear step (the only AND gates). The RTL
   writes it as AND / XOR / NOT on whole 64-bit words, which does all 64 columns at once.
   No lookup table means no table-timing leak and very little area.
3. **Diffusion**: each word is XORed with two rotated copies of itself
   (`x0 ^ (x0 >>> 19) ^ (x0 >>> 28)`, different amounts per word). One changed bit becomes
   three, and after a few rounds every output bit depends on every input bit.

In hardware a rotation is just wiring, so a round is about five levels of XOR / AND gates.
That is why more than one round fits in a clock cycle (section 6).

Compare the Verilog with `ROUND()` in `ref/ascon-c/asconaead128/round.h`: same lines, in
the same order.

## 4. Ascon-AEAD128 step by step (`rtl/ascon_core.v`)

```
          key, nonce            AD blocks              message blocks           key
              |                     |                        |                   |
  IV -> [ state ] -p12-> ^key -> absorb -p8-> ... -> ^1 -> absorb / emit -p8-> ... ^key -p12-> ^key -> tag
                                                     (domain                 ciphertext out
                                                      separation)
```

| Step | What happens | State of the FSM |
|---|---|---|
| Initialise | `x0 = IV`, `x1,x2 = key`, `x3,x4 = nonce`, 12 rounds, then XOR the key into `x3,x4` | `S_INIT` |
| Associated data | each 16-byte block is XORed into `x0,x1`, then 8 rounds | `S_AD`, `S_AD_P` |
| Domain separation | flip the top bit of `x4` | end of `S_AD_P` (or `S_AD` if there is no AD) |
| Message | ciphertext = `x0,x1 XOR plaintext`; the ciphertext stays in `x0,x1`; 8 rounds between blocks | `S_MSG`, `S_MSG_P` |
| Finalise | XOR the key into `x2,x3`, 12 rounds, tag = `x3,x4 XOR key` | `S_FIN` |

Details that are easy to get wrong (each one is a bug planted in `verif/inject_bug.py`):

- **Padding**. The last block of a stream is usually short. One byte `0x01` goes right
  after the data, so a message `AB` and a message `AB 00` do not look the same. If the data
  ends exactly on a block boundary, a whole extra block holding only the padding byte is
  absorbed (`pad_pend` in the RTL).
- **No AD at all** is special: nothing is absorbed, not even padding, but the domain
  separation bit is still flipped.
- **Domain separation** makes sure "AD = x, message = y" can never be confused with another
  split of the same bytes.
- **Decrypt** must leave the *ciphertext* in the rate, exactly as encrypt did, or the two
  sides compute different states. For a short last block only the bytes that carry data are
  replaced (`absorb` in the RTL).
- **The key goes in four times** (start, after the first permutation, before the last
  permutation, into the tag). Even if the state leaks later, running the permutation
  backwards does not give the key.

### What changed in the final standard

SP 800-232 is not the same as the Ascon v1.2 you find in older papers and GitHub projects:
bytes are loaded little-endian (byte 0 is the low byte of the word), the start values (IVs)
are new, and the padding byte is `0x01` at the low end instead of `0x80` at the high end.
Code written for v1.2 fails the new test vectors. This project follows SP 800-232 and is
checked against its official vectors.

## 5. Hash256, XOF128, CXOF128

Same sponge, rate 8 bytes, 12 rounds everywhere, no key:

- **Hash256**: absorb the message (padded like above), then give 4 blocks of 8 bytes.
- **XOF128**: same, but the caller chooses how many bytes come out.
- **CXOF128**: first absorbs a "customization string" (a label such as `"firmware-v1"`), so
  the same message hashed for two purposes gives unrelated results.

In the RTL they share `S_MSG / S_MSG_P` for absorbing and use `S_SQZ / S_SQZ_P` to give
output.

## 6. The hardware design decisions

**Streaming interface.** The core takes data as beats with valid / ready, up to 16 bytes
each, with a `last` flag. It never needs to know the total length in advance, and anything
can feed it: a CPU bus (this project), a FIFO, a DMA engine, an AXI-Stream adapter.

**Rounds per cycle (`RPC`).** The parameter chains 1, 2 or 4 copies of `ascon_round` between
the state registers.

| RPC | Cycles for a 16-byte AEAD block | LUTs (core, Yosys, Artix-7) | Meaning |
|---|---|---|---|
| 1 | 9 | about 2,300 | smallest, shortest critical path |
| 2 | 5 | about 3,800 | |
| 4 | 3 | about 5,800 | fastest per cycle, longest critical path |

More rounds per cycle means fewer cycles but a longer path through logic, so a lower
maximum clock frequency. Which one wins depends on where the bottleneck is. In the SoC the
CPU feeds the core over a slow bus, and `RPC = 1` is already faster than the CPU can supply
data (section 8), so the extra area of `RPC = 4` would buy nothing there. With a DMA engine
the answer changes. That is the kind of trade-off reasoning interviewers want to hear.

**One permutation instance.** The 12-round and 8-round permutations use the same logic; the
only difference is the starting round number (`pb_first`).

**Security choices** (also in the header of `ascon_core.v`):

- *Constant time.* The number of clock cycles depends only on the lengths, never on the
  key or data. The scoreboard checks this for every operation with a formula.
- *Decrypt never shows the computed tag.* It only says yes or no. If it showed the tag, an
  attacker could send a forged message with any tag, read the right one, and resend.
- *Wipe.* State and key copy are cleared when an operation ends, so nothing secret sits in
  registers between operations. An assertion checks it.
- *Unverified plaintext.* Decrypted bytes come out before the tag is checked, because the
  tag is only known at the end. The C driver wipes its buffer if the check fails.

What this design does **not** protect against: power or electromagnetic side channels
(measuring the chip while it works) and fault injection. Those need masking and redundancy,
which is a good follow-up project.

## 7. Verification (`verif/`)

Three layers, from quick to thorough:

1. **Known-answer tests** (`verif/tb_kat.sv`): all 4,228 official vectors. Each AEAD vector
   is run as encrypt, decrypt and a tampered decrypt. Proves the maths.
2. **Register-level test** (`verif/tb_mmio.sv`): the same vectors through the bus wrapper,
   the way software drives it.
3. **UVM** (`verif/uvm/`): constrained-random operations checked against the Ascon team's
   own C code.

Why UVM when the vectors already pass? The vectors use fixed keys, counting bytes as data
and lengths up to 32. They say nothing about stalls on the handshakes, a start pulse in the
middle of an operation, reset in the middle, back-to-back operations, long messages, random
data, or how long an operation takes. Those are where a correct algorithm in a wrong
circuit breaks.

How the UVM environment is built (`verif/uvm/README.md` has the full plan):

- **Driver** plays the user of the core. **Monitor** only watches pins and rebuilds each
  operation from what it saw. The scoreboard trusts the monitor, never the driver.
- **Scoreboard** recomputes every operation with the official C code through **DPI-C**
  (SystemVerilog calling C). The reference is code we did not write, so the same mistake
  cannot be in both.
- **Coverage** is about the *shape* of an operation, not data values: which mode, how the
  lengths sit against the block size, how each stream ended, where the padding byte landed,
  what the handshakes did. The permutation treats all data the same, so data values are
  not interesting; block boundaries are.
- **Assertions** hold the rules that are not about results: output beats stay stable until
  taken, decrypt hides the tag, the state is wiped, an operation ends within a fixed time.
- **Bug injection** proves the testbench. Six realistic bugs are planted one at a time and
  each must be caught. One of them (`no_wipe`) leaves every result correct; only an
  assertion sees it. That is the argument for assertions next to a scoreboard.

## 8. The SoC part (`rtl/ascon_mmio.v`, `soc/`)

`ascon_mmio.v` turns the streaming interface into registers at `0x3000_0000` on the
RV32IM SoC's bus. `soc/sw/common/ascon.h` is the C driver.

Rules the wrapper follows:

- Reads never change anything (the SoC's rule, so a load the pipeline repeats is harmless).
  An output beat is released by a write to `DOUT_ACK`, not by reading it.
- The key and nonce registers are write-only. After a decrypt the tag register reads zero.

Measured on the SoC (RTL simulation, 1024-byte message, `RPC = 1`):

| | Software (official optimised C) | Hardware | Speedup |
|---|---|---|---|
| Encrypt | 91,257 cycles | 2,947 cycles | 31x |
| Hash | 217,021 cycles | 2,064 cycles | 105x |

Read the numbers critically:

- Encryption takes 46 cycles per 16-byte block, but the core needs only 9. The other 37
  are the CPU loading 4 words, storing 4 words, polling a status bit, and doing it again for
  the output. Raising `RPC` to 4 changes nothing for encryption. A DMA engine that moves
  the data without the CPU would.
- Hashing is closer to the core's own speed (16 cycles per block against 13) because a
  hash block is only two words in and nothing out.
- The software baseline is built with the permutation as a loop, because the fully unrolled
  build does not fit the SoC's 16 KB of code memory. A CPU with more memory would run the
  software faster, and the speedup would be smaller.

## 9. Questions you should be able to answer

1. What does AEAD give that plain encryption does not? What is the associated data for?
2. What goes wrong if a nonce is reused with the same key?
3. What are rate and capacity? Why is the capacity never output?
4. What are the three steps of a round, and what would break without each one?
5. Why is the S-box written with AND / XOR instead of a lookup table?
6. Why does the round constant exist?
7. Why 12 rounds at the start and end but 8 between data blocks?
8. Where is the padding byte, and what happens when the data fills the last block exactly?
9. What is domain separation and where is it in the RTL?
10. Why must decrypt put the ciphertext, not the plaintext, into the state?
11. Why is the key XORed in again after the first permutation and around the last one?
12. Why does the core not output the tag when decrypting?
13. What does "constant time" mean here and how does the testbench prove it?
14. What does `RPC` trade? Which value would you tape out, and what would you measure
    first to decide?
15. Why is a reference model written by someone else worth more than your own?
16. Why does the scoreboard take its data from the monitor and not from the driver?
17. Which planted bug can only an assertion catch, and why?
18. What does your coverage model measure, and why not data values?
19. Why is the SoC speedup 31x when the core is far faster than that? What would you build
    next to raise it?
20. What attacks does this design not defend against?
21. What differs between Ascon v1.2 and SP 800-232, and how did you make sure you built the
    right one?

## 10. Make it yours

Change something, predict the effect, measure it. Suggestions, easiest first:

- Add CXOF128 to the C driver and test it on the SoC.
- Run `syn/synth_fpga.sh`, then Vivado, and add real timing for `RPC` 1, 2, 4.
- Add a seventh bug to `inject_bug.py` and see who catches it.
- Write a DMA engine (base address + length registers) and re-measure the speedup.
- Prove `a_wiped` and `a_dec_hides_tag` formally with SymbiYosys.
- Secure boot: hash the program with the core before jumping to it.
- A masked S-box (protection against power analysis). This is the step into real
  hardware-security work.
