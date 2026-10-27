# Clean-room MIT test suite for Motorola DSP56300 Address Generation Unit (AGU)
# Hardware Reference: DSP56300FM Chapter 4 (Sections 4.1 - 4.5)

import unittest
import dsp56300/state
import dsp56300/agu

suite "DSP56300 Address Generation Unit (AGU)":
  test "Linear Addressing (Mn = $FFFFFF)":
    var s: Dsp56300State
    s.reset()

    s.r[0] = 0x001000'u32
    s.m[0] = 0x00FFFFFF'u32 # Linear modifier
    s.n[0] = 0x000010'u32

    # (R0)+ post-increment
    let ea1 = s.aguCalculateEffectiveAddress(0, AguPostInc)
    check ea1 == 0x001000'u32
    check s.r[0] == 0x001001'u32

    # (R0)- post-decrement
    let ea2 = s.aguCalculateEffectiveAddress(0, AguPostDec)
    check ea2 == 0x001001'u32
    check s.r[0] == 0x001000'u32

    # (R0)+N0 post-increment by offset
    let ea3 = s.aguCalculateEffectiveAddress(0, AguPostIncOffset)
    check ea3 == 0x001000'u32
    check s.r[0] == 0x001010'u32

    # -(R0) pre-decrement
    let ea4 = s.aguCalculateEffectiveAddress(0, AguPreDec)
    check ea4 == 0x00100F'u32
    check s.r[0] == 0x00100F'u32

    # (R0+N0) indexed without update
    let ea5 = s.aguCalculateEffectiveAddress(0, AguIndexedOffset)
    check ea5 == 0x00101F'u32
    check s.r[0] == 0x00100F'u32 # R0 unchanged

  test "Modulo Addressing with Power-of-2 Base Boundary (Mn = M - 1)":
    var s: Dsp56300State
    s.reset()

    # Modulo buffer of size 5: M = 5 -> Mn = 4 ($000004)
    # Smallest power of 2 >= 5 is 8 (2^3 = 8).
    # Base address must have 3 LSBs = 0, e.g. base = $1000 (binary ...000)
    # Lower bound = $1000, Upper bound = $1000 + 5 - 1 = $1004.
    s.r[1] = 0x001000'u32
    s.m[1] = 0x000004'u32 # Modulo 5

    # Step forward 4 times: 1000 -> 1001 -> 1002 -> 1003 -> 1004
    for i in 0 .. 3:
      let ea = s.aguCalculateEffectiveAddress(1, AguPostInc)
      check ea == uint32(0x001000 + i)

    # Now at $1004 (upper bound). Next post-increment must wrap to base $1000!
    check s.r[1] == 0x001004'u32
    let eaWrap = s.aguCalculateEffectiveAddress(1, AguPostInc)
    check eaWrap == 0x001004'u32
    check s.r[1] == 0x001000'u32 # Wrapped to base!

    # Decrementing from lower bound ($1000) must wrap to upper bound ($1004)!
    let eaDecWrap = s.aguCalculateEffectiveAddress(1, AguPostDec)
    check eaDecWrap == 0x001000'u32
    check s.r[1] == 0x001004'u32 # Wrapped to upper bound!

  test "Reverse-Carry (Bit-Reversed) Addressing (Mn = $000000)":
    var s: Dsp56300State
    s.reset()

    # In 2k-point FFT addressing (e.g. 8-point FFT, k=3):
    # Step size is 2^(k-1) = 4 ($000004 in N).
    # With reverse-carry, adding 4 propagates carry from bit 2 toward bit 0,
    # generating bit-reversed addresses:
    # 0 (000_2) -> 4 (100_2) -> 2 (010_2) -> 6 (110_2) -> 1 (001_2) -> 5 (101_2) -> 3 (011_2) -> 7 (111_2)
    s.r[2] = 0x000000'u32
    s.m[2] = 0x000000'u32 # Reverse carry
    s.n[2] = 0x000004'u32 # Step 4

    let expected = [
      0x000000'u32, 0x000004'u32, 0x000002'u32, 0x000006'u32, 0x000001'u32,
      0x000005'u32, 0x000003'u32, 0x000007'u32,
    ]

    for exp in expected:
      let ea = s.aguCalculateEffectiveAddress(2, AguPostIncOffset)
      check ea == exp

  test "Multiple Wrap-Around Modulo Modifier (Mn = $8003 -> Modulo 4)":
    var s: Dsp56300State
    s.reset()

    # Mn = $8003: Bit 15=1, Bit 14=0, Modulo 4
    s.r[3] = 0x000100'u32
    s.m[3] = 0x008003'u32
    s.n[3] = 0x000006'u32 # Offset > M (6 > 4) supported in multiple wrap-around!

    # 100 + 6 = 106, modulo 4 within block of 4 (offset 6 mod 4 = 2) -> $102
    let ea = s.aguCalculateEffectiveAddress(3, AguPostIncOffset)
    check ea == 0x000100'u32
    check s.r[3] == 0x000102'u32
