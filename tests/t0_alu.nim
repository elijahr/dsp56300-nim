# Clean-room MIT test suite for Motorola DSP56300 56-Bit Fixed-Point Data ALU
# Hardware Reference: DSP56300FM Chapter 3, Chapter 13

import unittest
import dsp56300/state
import dsp56300/alu

suite "DSP56300 56-Bit Data ALU":

  test "56-bit accumulator pack and unpack":
    var s: Dsp56300State
    s.reset()

    # Positive value: A2=0x00, A1=0x400000, A0=0x123456
    s.a2 = 0x00'u8
    s.a1 = 0x400000'u32
    s.a0 = 0x123456'u32
    let valA = s.getA()
    check valA == 0x00400000123456i64

    # Negative value with extension: A2=0xFF, A1=0x800000, A0=0x000000
    s.a2 = 0xFF'u8
    s.a1 = 0x800000'u32
    s.a0 = 0x000000'u32
    let valNeg = s.getA()
    check valNeg < 0
    check valNeg == cast[int64](0xFFFF800000000000'u64)

    # Round trip from int64
    s.setA(valA)
    check s.a2 == 0x00'u8
    check s.a1 == 0x400000'u32
    check s.a0 == 0x123456'u32

  test "ADD, SUB, and Carry/Borrow/Overflow CCR flags":
    var s: Dsp56300State
    s.reset()

    # 1. Normal addition without overflow
    s.setA(0x00100000000000i64)
    s.aluAdd(0x00200000000000i64, isDstB = false)
    check s.getA() == 0x00300000000000i64
    check (s.sr and SR_Z) == 0
    check (s.sr and SR_N) == 0
    check (s.sr and SR_V) == 0
    check (s.sr and SR_C) == 0

    # 2. Addition resulting in zero
    s.setA(0x00100000000000i64)
    s.aluAdd(-0x00100000000000i64, isDstB = false)
    check s.getA() == 0
    check (s.sr and SR_Z) != 0

    # 3. Addition with 56-bit positive overflow
    s.setA(0x007FFFFFFFFFFFFFi64)
    s.aluAdd(0x00000000000001i64, isDstB = false)
    # Signs of inputs positive, result negative -> V and sticky L set
    check (s.sr and SR_V) != 0
    check (s.sr and SR_L) != 0

    # 4. Subtraction with borrow
    s.reset()
    s.setA(0x00000000000001i64)
    s.aluSub(0x00000000000002i64, isDstB = false)
    check s.getA() == -1i64
    check (s.sr and SR_N) != 0
    check (s.sr and SR_C) != 0 # Borrow generated

  test "Convergent vs Two's-Complement Rounding":
    var s: Dsp56300State

    # Case: A0 = $800000 (exactly 0.5), A1 LSB = 0 (even)
    # Convergent (RM = 0): rounds down (adds nothing)
    s.reset()
    s.sr = s.sr and not SR_RM # RM = 0
    s.a2 = 0x00'u8
    s.a1 = 0x000002'u32 # even LSB (bit 24 is 0 in A)
    s.a0 = 0x800000'u32 # 0.5
    s.aluRnd(isDstB = false)
    check s.a1 == 0x000002'u32
    check s.a0 == 0x000000'u32

    # Case: A0 = $800000 (exactly 0.5), A1 LSB = 1 (odd)
    # Convergent: rounds up to even
    s.reset()
    s.sr = s.sr and not SR_RM
    s.a2 = 0x00'u8
    s.a1 = 0x000001'u32 # odd LSB
    s.a0 = 0x800000'u32
    s.aluRnd(isDstB = false)
    check s.a1 == 0x000002'u32
    check s.a0 == 0x000000'u32

    # Two's-complement (RM = 1): always rounds up on >= 0.5
    s.reset()
    s.sr = s.sr or SR_RM # RM = 1
    s.a2 = 0x00'u8
    s.a1 = 0x000002'u32 # even
    s.a0 = 0x800000'u32
    s.aluRnd(isDstB = false)
    check s.a1 == 0x000003'u32 # Rounded up despite even
    check s.a0 == 0x000000'u32

  test "Arithmetic Saturation Mode (SM = 1)":
    var s: Dsp56300State
    s.reset()
    s.sr = s.sr or SR_SM # Enable 48-bit saturation mode

    # Exceeding positive 48-bit range ($00:7FFFFF:FFFFFF)
    s.a2 = 0x01'u8
    s.a1 = 0x000000'u32
    s.a0 = 0x000000'u32
    s.aluAdd(0x00000000000000i64, isDstB = false)
    check s.getA() == CONST_POS_SAT48
    check (s.sr and SR_V) != 0
    check (s.sr and SR_L) != 0

    # Exceeding negative 48-bit range
    s.reset()
    s.sr = s.sr or SR_SM
    s.a2 = 0xFE'u8
    s.a1 = 0x7FFFFF'u32
    s.a0 = 0xFFFFFF'u32
    s.aluAdd(0x00000000000000i64, isDstB = false)
    check s.getA() == CONST_NEG_SAT48
    check (s.sr and SR_V) != 0
    check (s.sr and SR_L) != 0

  test "Shifter / Limiter on 24-bit Bus Read":
    var s: Dsp56300State
    s.reset()

    # Normal un-limited read
    s.a2 = 0x00'u8
    s.a1 = 0x123456'u32
    s.a0 = 0x789ABC'u32
    let readVal = s.readAccumulator24(isB = false)
    check readVal == 0x123456'u32
    check (s.sr and SR_L) == 0

    # Positive limiting (extension register in use, bit 55 == 0)
    s.a2 = 0x01'u8
    s.a1 = 0x123456'u32
    let limitedPos = s.readAccumulator24(isB = false)
    check limitedPos == CONST_POS_LIMIT24 # $7FFFFF
    check (s.sr and SR_L) != 0             # Sticky L set

    # Negative limiting (extension register in use, bit 55 == 1)
    s.reset()
    s.a2 = 0xFE'u8
    s.a1 = 0x123456'u32
    let limitedNeg = s.readAccumulator24(isB = false)
    check limitedNeg == CONST_NEG_LIMIT24 # $800000
    check (s.sr and SR_L) != 0

  test "Fractional Multiplication and MAC":
    var s: Dsp56300State
    s.reset()

    # Multiply 0.5 * 0.5:
    # In fractional format, 0.5 is represented as $400000 (int32 4194304)
    # 0.5 * 0.5 = 0.25 -> represented as $200000 in MSP (bit 45 set)
    let half = 0x400000'i32
    s.aluMpy(half, half, isDstB = false)
    check s.a1 == 0x200000'u32
    check s.a0 == 0x000000'u32
    check s.a2 == 0x00'u8

    # MAC: Accumulate another 0.5 * 0.5:
    # 0.25 + 0.25 = 0.5 -> $400000
    s.aluMac(half, half, isDstB = false)
    check s.a1 == 0x400000'u32
    check s.a0 == 0x000000'u32

  test "Shift & Rotate Operations":
    var s: Dsp56300State
    s.reset()

    s.setA(0x00100000000000i64)
    s.aluAsl(isDstB = false, shiftCount = 1)
    check s.getA() == 0x00200000000000i64

    s.aluAsr(isDstB = false, shiftCount = 1)
    check s.getA() == 0x00100000000000i64

    # ROL / ROR with carry
    s.sr = s.sr or SR_C
    s.aluRol(isDstB = false)
    check (cast[uint64](s.getA()) and 1'u64) == 1'u64

  test "Count Leading Bits (CLB)":
    var s: Dsp56300State
    s.reset()

    # If all zeros, CLB returns 0
    s.setA(0)
    s.aluClb(isSrcB = false, isDstB = true)
    check s.b1 == 0'u32
    check (s.sr and SR_Z) != 0

    # Positive number with 9 leading zeros:
    # Bit 55..47 are zero, bit 46 is 1 -> 9 leading zeros -> 9 - 9 = 0
    s.setA(1'i64 shl 46)
    s.aluClb(isSrcB = false, isDstB = true)
    check s.b1 == 0'u32

    # Positive number with 10 leading zeros -> 9 - 10 = -1 (two's complement 24-bit $FFFFFF)
    s.setA(1'i64 shl 45)
    s.aluClb(isSrcB = false, isDstB = true)
    check s.b1 == 0x00FFFFFF'u32
    check (s.sr and SR_N) != 0

  test "Non-restoring Division (DIV)":
    var s: Dsp56300State
    s.reset()

    # Divide 0.25 ($200000) by 0.5 ($400000) -> Quotient should be 0.5 ($400000)
    # Dividend in A: MSP = $200000
    s.a1 = 0x200000'u32
    s.a0 = 0x000000'u32
    s.a2 = 0x00'u8
    let divisor = 0x400000'u32

    # Execute 24 DIV iterations
    for _ in 1..24:
      s.aluDiv(divisor, isDstB = false)

    # In non-restoring division, formed quotient is in A0
    check s.a0 == 0x400000'u32
