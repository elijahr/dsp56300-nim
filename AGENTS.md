# Agents

Instructions for AI coding agents working on this repository.

This repository provides a clean-room MIT implementation of the Motorola DSP56300 / DSP56311 digital signal processor core and on-chip peripherals.

Licence: MIT. Contributions must be MIT compatible and strictly follow clean-room implementation rules.

## Clean-Room Rules

- Never inspect, copy, or transliterate GPL-licensed DSP56300 emulator code.
- All algorithms, register layouts, bitmasks, and addressing modes must be derived directly from official Motorola datasheets and hardware user manuals:
  - Motorola DSP56300 24-Bit Digital Signal Processor Family Manual (DSP56300FM)
  - Motorola DSP56311 24-Bit Digital Signal Processor User's Manual (DSP56311UM)
- Maintain the pure C11 ABI surface declared in `include/dsp56300.h`.

## Build and Test

The repository supports two build paths:
1. Pinned Nim compiler (`.nim-version` specifies the required toolchain).
2. Pre-generated C distribution (`c_src/`) requiring only a standard C11 compiler.

### Test Presets

```bash
# Pinned Nim compiler build and unit test suite
cmake --preset t0
cmake --build --preset t0
ctest --preset t0

# Pre-generated C distribution build and ABI test
cmake --preset c-dist
cmake --build --preset c-dist
ctest --preset c-dist
```

### Pre-generated C Distribution

When modifying Nim core sources under `src/`, regenerate the C distribution files using:

```bash
./tools/generate_c_dist.sh
```

Always verify that `ctest --preset c-dist` passes after updating the distribution.

## Comments and Style

- Comments explain why a decision was made, not what the code does.
- Datasheet citations and hardware formulas are encouraged.
- Do not cite external task ledgers, internal issue numbers, or plans in comments or commit messages.
