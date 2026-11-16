# RTL to GDSII: the Ascon peripheral on SkyWater 130 nm (LibreLane)

Hardens `ascon_mmio` (the core plus its register wrapper) into a layout. The wrapper is the
block to harden, not the bare core: the core has about 800 pins (key, nonce, data in, data
out, tags), the wrapper has 100 (one 32-bit bus).

**Not run yet.** This config is a starting point with the same settings as
`asic/riscv_cpu` in the SoC repository. Run it, read the timing report, then tighten the
clock.

| Setting | Value | Why |
|---|---|---|
| PDK | sky130A (default) | open-source 130 nm process |
| `RPC` | 1 | one round per cycle: smallest area and shortest path. Try 2 and 4 and compare |
| Clock | 20 ns (50 MHz) first run | safe start; one round is only about 5 gate levels, so expect a lot of slack |
| Core utilisation | 40 % | |
| Placement density | 50 % | |

## Run

Inside the LibreLane Nix shell (`cd ~/librelane && nix-shell`):

```sh
cd <this repo>/asic/ascon_mmio
librelane config.json
```

The result is in `runs/<tag>/final/`: `gds/ascon_mmio.gds` plus timing, area and power
reports. To look at the layout:

```sh
librelane --last-run --flow OpenInKLayout config.json
```

## What to report

For `RPC` = 1, 2 and 4 (change `SYNTH_PARAMETERS`): cell area, worst slack at the clock you
ran, and from those the best clock period. Throughput is `128 bits / (cycles per block x
clock period)`, with 9, 5 and 3 cycles per block. The interesting result is which `RPC`
gives the most throughput per unit of area.
