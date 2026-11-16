# UVM verification of the Ascon core

Constrained-random operations (encrypt, decrypt, Hash256, XOF128, CXOF128) on `ascon_core`,
each one recomputed by the Ascon team's own C code through DPI-C. Written for Cadence
Xcelium + IMC, brought up on Verilator. Same folder layout as the environments in
riscv-rv32im-soc (`env_lib/`, `env/`, `test/`, `sim/`).

```
  sequence -> driver -> pins -> ascon_core
                         |
              monitor <--+        (rebuilds every operation from the pins alone)
                 |
        +--------+---------+
        v                  v
   scoreboard          coverage              ascon_if: 16 assertions, 9 cover properties
        |
  official C code (DPI-C)
```

## What is checked

| Check | Where | What it proves |
|---|---|---|
| Output bytes, tag, accept / reject | `ascon_sb.sv` against `ref/` | the result of every operation is what the standard says |
| Cycle count of every operation | `ascon_sb.sv`, `expected_cycles()` | the run time depends only on the lengths, never on key or data (constant time) |
| Every driven operation was checked | `ascon_env.sv`, `check_phase` | no operation was lost between monitor and scoreboard |
| Handshake rules | `ascon_if.sv` (SVA) | output beats stay stable until taken, `done` is one cycle, nothing is accepted while idle |
| Decrypt never shows the tag | `a_dec_hides_tag` | software cannot ask the core for the tag of a forged message |
| State and key are wiped | `a_wiped` | nothing secret stays in registers between operations |
| No bits outside the valid bytes | `a_dout_no_leak` | a short output beat does not show state bits |
| An operation always ends | `a_aead_finishes` | no hang after the last message beat |
| The testbench obeys the protocol | `a_tb_*` | the stimulus itself is legal |

The cycle count is checked for every operation in which the output side did not make the
core wait. Cycles the core spent waiting for input are measured by the monitor and
subtracted.

## Tests

| Test | What it does |
|---|---|
| `ascon_corner_test` | every length around the block boundaries, one by one, nothing stalls: 565 operations with exact cycle counts |
| `ascon_rand_test` | random modes, lengths, data, stalls, gaps |
| `ascon_tamper_test` | decrypts with one bit flipped in the tag, ciphertext, associated data, key or nonce: all must be refused |
| `ascon_b2b_test` | each operation starts in the cycle after the previous `done` |
| `ascon_stall_test` | slow input and slow output; the next operation starts while the last output beat is still waiting |
| `ascon_poke_test` | a second `start` in the middle of every operation: must be ignored |
| `ascon_reset_test` | reset in the middle of every second operation: the next one must be right, the core wiped |
| `ascon_full_test` | all of the above in one run, for coverage closure |

Sequences steer the item through knobs set before `randomize()` (mode weights, fixed
lengths, flow, damage rate), see `ascon_xtn.sv`.

## Functional coverage (`ascon_coverage.sv`)

The permutation scrambles all data the same way, so data values are not what coverage is
about. The shape of an operation is: how its lengths sit against the block size, how each
stream ended, where the padding byte landed, what the handshakes were doing.

| Covergroup | Points and crosses |
|---|---|
| `cg_aead` | direction x AD length class x message length class (50 bins); how each stream ended (empty, short last block, full block marked last, full block then an empty last beat) per direction; all 16 padding positions for both streams |
| `cg_decrypt` | accepted / refused x length classes |
| `cg_hash` | Hash256 / XOF128 / CXOF128 x message length class and stream ending; all 8 padding positions |
| `cg_xof` | XOF / CXOF x output length class (0, short, one block, several, exact multiple); output length modulo 8 |
| `cg_cxof` | customization string class x message class; how the string ended |
| `cg_flow` | per mode: waited for input, output stalled, poked, back to back; started with an output beat still pending |

Length classes are: zero, less than a block, exactly one block, several blocks with a short
last one, several full blocks.

The crosses and the padding positions are also kept in a plain table of 257 named bins,
printed at the end of every run (`bins hit: n of 257`, with the list of holes). That makes
coverage visible on Verilator, which has no covergroups. On Xcelium, IMC is the reference
(it also counts the single coverpoints, so its bin total is larger).

## Running on Xcelium

Copy the whole repository to the server (the file lists point at `../../../rtl` and
`../../../ref`), then:

```sh
cd verif/uvm/sim
make run TEST=ascon_corner_test         # one test (SEED=, NOPS=, VERB= optional)
make regress                            # everything in regress.list
make cov_merge cov_report               # IMC: merged coverage, text reports in reports/
make cov_gui                            # IMC GUI
make gui TEST=ascon_stall_test          # SimVision waveforms
make regress RPC=4                      # the 4-rounds-per-cycle core (own snapshot and scope)
```

Each log ends with `TEST PASSED: <test>` or `TEST FAILED: <test> (n errors)`.
`xrun` compiles the C reference model (`ref.f`) and links it by itself.

## Running on Verilator

```sh
git clone https://github.com/accellera-official/uvm-core
UVM_HOME=$PWD/uvm-core/src ./run_verilator.sh ascon_full_test
UVM_HOME=$PWD/uvm-core/src RPC=4 ./run_verilator.sh ascon_rand_test +NOPS=500
```

Needs Verilator 5.036 or newer and the `z3` solver for the constraints. The build takes a
few minutes (it compiles the whole UVM library). Assertions are on (`--assert`).
For waveforms without a licence add `+define+DUMP` to the build and open `sim/waves.vcd`
in GTKWave.

## Results

Measured on Verilator 5.049 with uvm-core, `./run_verilator.sh regress`, for each of
`RPC` = 1, 2 and 4. **Not run on Xcelium yet**: the IMC numbers (code coverage, covergroup
and assertion coverage) still have to be collected with `make regress cov_merge cov_report`.

| Test (`sim/regress.list`) | Seed | Operations checked | RPC 1 | RPC 2 | RPC 4 |
|---|---|---|---|---|---|
| `ascon_corner_test` | 1 | 565 | pass | pass | pass |
| `ascon_rand_test` | 1 | 400 | pass | pass | pass |
| `ascon_rand_test` | 2 | 400 | pass | pass | pass |
| `ascon_tamper_test` | 11 | 300 | pass | pass | pass |
| `ascon_b2b_test` | 21 | 300 | pass | pass | pass |
| `ascon_stall_test` | 31 | 300 | pass | pass | pass |
| `ascon_poke_test` | 41 | 200 | pass | pass | pass |
| `ascon_reset_test` | 51 | 99 (+101 cut off by reset) | pass | pass | pass |
| `ascon_full_test` | 61 | 1,664 | pass | pass | pass |

9 of 9 pass for every `RPC`, 4,228 operations checked per regression, 0 wrong results,
0 wrong run lengths, no assertion failures. `ascon_full_test` alone hits all 257 bins of
the functional table.

## Planted bugs

`python3 ../inject_bug.py <name>` plants one bug in `rtl/ascon_core.v` (and `restore` puts
the clean file back). Each was run with `ascon_full_test +NOPS=100` at `RPC` = 1:
1,115 operations checked, 413 of them decrypts.

| Bug | What it is | Scoreboard errors | Assertion errors | Result |
|---|---|---|---|---|
| `pad80` | padding byte `0x80` instead of `0x01` (the older Ascon v1.2 rule) | 972 | 0 | FAILED |
| `six_rounds` | 6 rounds between data blocks instead of 8 (the old Ascon-128 parameter) | 686 wrong results + 568 wrong run lengths | 0 | FAILED |
| `dec_absorb` | decrypt absorbs the plaintext instead of the ciphertext | 329 | 0 | FAILED |
| `skip_dsep` | domain-separation bit forgotten when there is no associated data | 62 | 0 | FAILED |
| `tag_leak` | decrypt shows the tag it computed | 413 | 413 (`a_dec_hides_tag`) | FAILED |
| `no_wipe` | state and key left in the registers after an operation | **0** | 2,412 (`a_wiped`) | FAILED |

All six are caught. Two things worth noticing:

- `skip_dsep` only shows on operations with empty associated data (62 of 1,115). A test
  that always used some associated data would pass with this bug in. That is what the
  corner sequence and the length-class coverage are for.
- `no_wipe` gives correct results every time. The scoreboard has nothing to complain
  about; only the assertion sees that secrets stay behind. A security property that is not
  visible at the outputs needs an assertion (or a formal proof).

Plant `six_rounds` with `RPC` = 1 or 2 only: with 4 rounds per cycle the round counter
steps 6, 10, 14 and never lands on 12, so the permutation never ends and the test stops on
its timeout instead of reporting mismatches.
