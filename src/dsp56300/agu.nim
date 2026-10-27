# Clean-room MIT implementation of Motorola DSP56300 Address Generation Unit (AGU)
# Hardware Reference: DSP56300FM Chapter 4 (Sections 4.1 - 4.5)

import state

type AguMode* = enum
  AguNoUpdate # (Rn)
  AguPostInc # (Rn)+
  AguPostDec # (Rn)-
  AguPostIncOffset # (Rn)+Nn
  AguPostDecOffset # (Rn)-Nn
  AguPreDec # -(Rn)
  AguIndexedOffset # (Rn+Nn)

proc bitReverse24*(v: uint32): uint32 {.inline.} =
  var x = v and 0x00FFFFFF'u32
  var r = 0'u32
  for i in 0 .. 23:
    r = (r shl 1) or (x and 1'u32)
    x = x shr 1
  return r

# Smallest power of 2 >= M (where M >= 2)
proc nextPowerOf2(m: uint32): uint32 {.inline.} =
  var p = 1'u32
  while p < m and p < 0x00800000'u32:
    p = p shl 1
  return p

proc updateAddress*(rnVal: uint32, delta: int32, mnVal: uint32): uint32 =
  let mn16 = mnVal and 0x00FFFF'u32

  # 1. Reverse-Carry Modifier (Mn = $XX0000)
  if mn16 == 0x0000'u32:
    let rRev = bitReverse24(rnVal)
    let dRev = bitReverse24(cast[uint32](delta) and 0x00FFFFFF'u32)
    let sumRev = (rRev + dRev) and 0x00FFFFFF'u32
    return bitReverse24(sumRev)

  # 2. Linear Modifier (Mn = $XXFFFF)
  if mn16 == 0xFFFF'u32:
    return mask24(uint32(int32(rnVal) + delta))

  # 3. Multiple Wrap-Around Modulo Modifier ($XX8001..$XXBFFF)
  # Bit 15 is 1, bit 14 is 0
  if (mn16 and 0xC000'u32) == 0x8000'u32:
    let m = (mn16 and 0x3FFF'u32) + 1'u32 # Modulo 2^k
    let mask = m - 1'u32
    let base = rnVal and not mask
    let offset = (rnVal + cast[uint32](delta)) and mask
    return mask24(base or offset)

  # 4. Standard Modulo Modifier ($XX0001..$XX7FFF)
  if mn16 >= 0x0001'u32 and mn16 <= 0x7FFF'u32:
    let m = mn16 + 1'u32 # Modulus M in range 2..32768
    let pow2 = nextPowerOf2(m)
    let baseMask = not (pow2 - 1'u32)
    let base = rnVal and baseMask
    let lower = base
    let upper = base + m - 1'u32

    var newAddr = int64(rnVal) + int64(delta)
    if newAddr > int64(upper):
      newAddr = newAddr - int64(m)
    elif newAddr < int64(lower):
      newAddr = newAddr + int64(m)

    return mask24(uint32(newAddr))

  # Fallback to linear
  return mask24(uint32(int32(rnVal) + delta))

proc aguCalculateEffectiveAddress*(
    s: var Dsp56300State, regIdx: int, mode: AguMode
): uint32 =
  let rVal = s.r[regIdx]
  let nVal = signExtend24(s.n[regIdx])
  let mVal = s.m[regIdx]

  case mode
  of AguNoUpdate:
    return rVal
  of AguPostInc:
    s.r[regIdx] = updateAddress(rVal, 1, mVal)
    return rVal
  of AguPostDec:
    s.r[regIdx] = updateAddress(rVal, -1, mVal)
    return rVal
  of AguPostIncOffset:
    s.r[regIdx] = updateAddress(rVal, nVal, mVal)
    return rVal
  of AguPostDecOffset:
    s.r[regIdx] = updateAddress(rVal, -nVal, mVal)
    return rVal
  of AguPreDec:
    let updated = updateAddress(rVal, -1, mVal)
    s.r[regIdx] = updated
    return updated
  of AguIndexedOffset:
    # (Rn + Nn) without modifying Rn
    return updateAddress(rVal, nVal, mVal)
