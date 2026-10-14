# dsp56300-nim

Clean-room MIT Motorola DSP56300 / DSP56311 CPU core and peripheral emulator implemented in Nim with a canonical pure C11 ABI.

## Architecture

- **Core Register State**: 24-bit Data ALU input registers (`X0`, `X1`, `Y0`, `Y1`), 56-bit accumulators (`A`, `B`), 24-bit Address Generation Unit registers (`R0`..`R7`, `N0`..`N7`, `M0`..`M7`), and Program Control Unit registers (`PC`, `SR`, `OMR`, `LA`, `LC`, `SP`, `SSH`, `SSL`, `VBA`, `EP`, `SZ`, `SC`).
- **Memory Subsystem**: 24-bit addressable `X:`, `Y:`, and `P:` memory spaces supporting internal single-cycle RAM, bootstrap ROM, and peripheral memory mapping (`$FFFF80`..`$FFFFFF`).
- **Data ALU**: 56-bit fixed-point arithmetic, fractional multiplication and multiply-accumulate, non-restoring division (`DIV`), count leading bits (`CLB`), shift/rotate operations, convergent and two's-complement rounding, and arithmetic saturation mode.
- **Address Generation Unit (AGU)**: Address register indirect modes with Linear (`$FFFFFF`), Modulo (`$000001`..`$007FFF`), Reverse-Carry / Bit-Reversed (`$000000`), and Multiple Wrap-Around Modulo (`$XX8001`..`$XXBFFF`).
- **Hardware Loops**: Nested hardware DO loops (`LA`, `LC`, system stack push/pop), `DO FOREVER`, `ENDDO`, and `REP`.
- **Peripherals**: DSP56311 on-chip peripherals including HDI08 Host Interface, Dual ESAI audio interfaces, 6-channel DMA controller, and triple timer module.
- **Dual Build Path**: Directly buildable via the pinned Nim toolchain (`cmake --preset t0`) or via the bundled pre-generated pure C11 distribution (`cmake --preset c-dist`) requiring no Nim installation.

## Clean-Room Provenance

This codebase is a clean-room implementation authored from first principles using Motorola hardware reference manuals:
- *DSP56300 24-Bit Digital Signal Processor Family Manual* (DSP56300FM)
- *DSP56311 24-Bit Digital Signal Processor User's Manual* (DSP56311UM)

It contains no code copied or derived from GPL-licensed implementations.

## Building and Testing

### Prerequisites
- CMake 3.26+
- C11 compiler (Clang, GCC, MSVC)
- Nim 2.2.10 (optional; only needed when modifying Nim sources)

### CMake Presets

```bash
# Build and run tests with Nim compiler:
cmake --preset t0
cmake --build --preset t0
ctest --preset t0

# Build and run C11 ABI test using pre-generated C distribution:
cmake --preset c-dist
cmake --build --preset c-dist
ctest --preset c-dist
```

## License

MIT License
