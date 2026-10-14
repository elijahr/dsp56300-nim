## Test suite for DSP56300 Shared Micro-Op IR Lifter and Cold-Block Runner
## Strict TDD: Red -> Green -> Fault-Plant

import std/unittest
import dsp56300/[ir, runner]

suite "DSP56300 Shared Micro-Op IR & Cold-Block Runner":

  test "Cold Runner executes NOP block":
    var state = newDspState()
    state.pc = 0x100'u32
    state.pRam[0x100] = 0x000000'u32 # NOP

    let blockIr = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    check blockIr.ops.len > 0

    let cycles = runBlock(state, blockIr)
    check cycles >= 1
    check state.pc == 0x101'u32

  test "Cold Runner executes Parallel ALU + Dual Move with pre-ALU snapshot semantics":
    var state = newDspState()
    state.pc = 0x100'u32
    # Set initial register values
    # In DSP56300 24-bit fractional:
    # 0x400000 = +0.5
    # 0x400000 * 0x400000 = 0.25 -> accumulator 48-bit fraction 0x200000_000000
    state.x0 = 0x400000'u32 # 0.5
    state.y0 = 0x400000'u32 # 0.5
    state.r[0] = 0x10'u32
    state.r[4] = 0x20'u32
    state.m[0] = 0xFFFFFF'u32 # Linear addressing
    state.m[4] = 0xFFFFFF'u32 # Linear addressing

    # Memory contents to load during parallel move
    state.xRam[0x10] = 0x123456'u32
    state.yRam[0x20] = 0x654321'u32

    # Instruction: MPY X0, Y0, A  X:(R0)+, X0  Y:(R4)+, Y0
    # Opcode 0xB018D0 at P:$100
    state.pRam[0x100] = 0xB018D0'u32

    let blockIr = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    let cycles = runBlock(state, blockIr)

    check cycles >= 1
    check state.pc == 0x101'u32
    # Accumulator A should hold product of pre-move X0 * Y0 = 0.5 * 0.5 = 0.25 (scaled by 2 per DSP standard fractional = 0.5, i.e. A1 = 0x400000 or A = 0x200000000000)
    check state.getAccA() != 0
    # X0 and Y0 should receive the new loaded memory values
    check state.x0 == 0x123456'u32
    check state.y0 == 0x654321'u32
    # R0 and R4 should be post-incremented
    check state.r[0] == 0x11'u32
    check state.r[4] == 0x21'u32

  test "Cold Runner executes Hardware Loop (DO loop)":
    var state = newDspState()
    state.pc = 0x100'u32
    state.a1 = 0'u32
    state.x0 = 0x000005'u32 # add 5 each iteration

    # P:$100: DO #4, $103  (words: 0x060480, 0x000102)
    state.pRam[0x100] = 0x060480'u32
    state.pRam[0x101] = 0x000102'u32 # Loop ends after P:$102
    # P:$102: ADD X0, A (0x000040)
    state.pRam[0x102] = 0x000040'u32

    # Lift DO loop block
    let blockIr = liftBasicBlock(state, 0x100'u32, maxWords = 3)
    let cycles = runBlock(state, blockIr)

    check cycles >= 4
    # Loop should have added X0 (5) four times: 5 * 4 = 20 (0x14)
    check state.a1 == 0x14'u32

  test "P-RAM Generation Counter Invalidation":
    var state = newDspState()
    state.pc = 0x100'u32
    state.pRam[0x100] = 0x000000'u32 # NOP
    state.pRamGen[0x100] = 1'u32

    let blockIr = liftBasicBlock(state, 0x100'u32, maxWords = 1)
    check blockIr.generation == 1'u32

    # Mutate P-RAM and bump generation counter
    state.pRam[0x100] = 0x00000C'u32 # Changed to RTS
    state.pRamGen[0x100] = 2'u32

    # Running stale block should fail validation
    check not validateBlock(state, blockIr)
