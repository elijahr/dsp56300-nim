# Clean-room MIT implementation of Motorola DSP56300 56-Bit Fixed-Point Data ALU
# Hardware Reference: DSP56300FM Chapter 3, Chapter 13

import state

const
  CONST_POS_SAT48* = 0x007FFFFFFFFFFFi64
  CONST_NEG_SAT48* = cast[int64](0xFF80000000000000'u64)
  CONST_POS_LIMIT24* = 0x007FFFFF'u32
  CONST_NEG_LIMIT24* = 0x00800000'u32
  CONST_POS_LIMIT48* = 0x007FFFFFFFFFFF'u64
  CONST_NEG_LIMIT48* = 0x00800000000000'u64

# Extract bit helpers on int64 accumulator
proc bit55*(v: int64): uint32 {.inline.} =
  uint32((cast[uint64](v) shr 55) and 1'u64)

proc bit47*(v: int64): uint32 {.inline.} =
  uint32((cast[uint64](v) shr 47) and 1'u64)

proc bit46*(v: int64): uint32 {.inline.} =
  uint32((cast[uint64](v) shr 46) and 1'u64)

proc bit45*(v: int64): uint32 {.inline.} =
  uint32((cast[uint64](v) shr 45) and 1'u64)

proc bit44*(v: int64): uint32 {.inline.} =
  uint32((cast[uint64](v) shr 44) and 1'u64)

proc bit*(v: int64, b: int): uint32 {.inline.} =
  uint32((cast[uint64](v) shr b) and 1'u64)

# Sign extension from 56-bit to 64-bit int
proc signExtend56*(raw: uint64): int64 {.inline.} =
  if (raw and (1'u64 shl 55)) != 0:
    cast[int64](raw or 0xFF00000000000000'u64)
  else:
    cast[int64](raw and 0x00FFFFFFFFFFFFFF'u64)

# Calculate Extension (E) and Unnormalized (U) flags
proc calcExtensionFlag*(val: int64, sr: uint32): bool =
  let sMode = (sr shr 10) and 0x03'u32
  let u = cast[uint64](val)
  case sMode
  of 0: # No scaling: signed integer is bits 55..47 (9 bits)
    let top9 = (u shr 47) and 0x1FF'u64
    return top9 != 0x000'u64 and top9 != 0x1FF'u64
  of 1: # Scale down: signed integer is bits 55..48 (8 bits)
    let top8 = (u shr 48) and 0xFF'u64
    return top8 != 0x00'u64 and top8 != 0xFF'u64
  of 2: # Scale up: signed integer is bits 55..46 (10 bits)
    let top10 = (u shr 46) and 0x3FF'u64
    return top10 != 0x000'u64 and top10 != 0x3FF'u64
  else:
    let top9 = (u shr 47) and 0x1FF'u64
    return top9 != 0x000'u64 and top9 != 0x1FF'u64

proc calcUnnormalizedFlag*(val: int64, sr: uint32): bool =
  let sMode = (sr shr 10) and 0x03'u32
  case sMode
  of 0: # U = (Bit 47 xor Bit 46) == 0 (identical MSBs)
    return (val.bit(47) xor val.bit(46)) == 0
  of 1: # U = (Bit 48 xor Bit 47) == 0
    return (val.bit(48) xor val.bit(47)) == 0
  of 2: # U = (Bit 46 xor Bit 45) == 0
    return (val.bit(46) xor val.bit(45)) == 0
  else:
    return (val.bit(47) xor val.bit(46)) == 0

# Calculate S (Scaling) flag update
proc updateScalingFlag*(s: var Dsp56300State, val: int64) =
  let sMode = (s.sr shr 10) and 0x03'u32
  var growth = false
  case sMode
  of 0: # No scaling: A46 XOR A45
    growth = (val.bit(46) xor val.bit(45)) != 0
  of 1: # Scale down: A47 XOR A46
    growth = (val.bit(47) xor val.bit(46)) != 0
  of 2: # Scale up: A45 XOR A44
    growth = (val.bit(45) xor val.bit(44)) != 0
  else:
    discard
  if growth:
    s.sr = s.sr or SR_S

# Arithmetic Saturation Mode (SM = 1) application
proc applyArithmeticSaturation*(val: int64, sr: var uint32, saturated: var bool): int64 =
  if (sr and SR_SM) == 0:
    saturated = false
    return val

  let u = cast[uint64](val)
  let ext7 = uint32((u shr 55) and 1'u64)
  let ext0 = uint32((u shr 48) and 1'u64)
  let msp23 = uint32((u shr 47) and 1'u64)

  # Check Table 3-1
  if ext7 == 0:
    if ext0 != 0 or msp23 != 0:
      sr = sr or SR_V or SR_L
      saturated = true
      return CONST_POS_SAT48
  else: # ext7 == 1
    if ext0 == 0 or msp23 == 0:
      sr = sr or SR_V or SR_L
      saturated = true
      return CONST_NEG_SAT48

  saturated = false
  return val

# Common CCR Update for Arithmetic operations
proc updateArithmeticCcr*(s: var Dsp56300State, res: int64, c: bool, v: bool) =
  var ccr = s.sr and not (SR_C or SR_V or SR_Z or SR_N or SR_U or SR_E)
  if c: ccr = ccr or SR_C


  if v: ccr = ccr or SR_V or SR_L # Overflow sets sticky L bit

  # Zero check (all 56 bits 0)
  if (cast[uint64](res) and 0x00FFFFFFFFFFFFFF'u64) == 0:
    ccr = ccr or SR_Z

  # Negative check (bit 55)
  if res.bit55 != 0:
    ccr = ccr or SR_N

  # Extension and Unnormalized checks
  if calcExtensionFlag(res, s.sr):
    ccr = ccr or SR_E
  if calcUnnormalizedFlag(res, s.sr):
    ccr = ccr or SR_U

  s.sr = ccr

# Common CCR Update for Logical operations
proc updateLogicalCcr*(s: var Dsp56300State, res: int64) =
  # Logical instructions clear V, leave C, S, L unchanged, and update N and Z based on MSP (bit 47)
  var ccr = s.sr and not (SR_V or SR_Z or SR_N or SR_U or SR_E)
  let msp = (cast[uint64](res) shr 24) and 0x00FFFFFF'u64
  if msp == 0:
    ccr = ccr or SR_Z
  if (msp and 0x00800000'u64) != 0:
    ccr = ccr or SR_N
  s.sr = ccr

# 24-Bit / 48-Bit Bus Read with Shifter / Limiter
proc readAccumulator24*(s: var Dsp56300State, isB: bool): uint32 =
  let val = if isB: s.getB() else: s.getA()
  s.updateScalingFlag(val)

  # Check extension in use
  if calcExtensionFlag(val, s.sr):
    s.sr = s.sr or SR_L # Limiter fired -> set sticky L bit
    if val.bit55 == 0:
      return CONST_POS_LIMIT24
    else:
      return CONST_NEG_LIMIT24

  let sMode = (s.sr shr 10) and 0x03'u32
  let u = cast[uint64](val)
  case sMode
  of 0: # No scaling: A1
    return uint32((u shr 24) and 0x00FFFFFF'u64)
  of 1: # Scale down: shift right by 1
    return uint32((u shr 25) and 0x00FFFFFF'u64)
  of 2: # Scale up: shift left by 1
    return uint32((u shr 23) and 0x00FFFFFF'u64)
  else:
    return uint32((u shr 24) and 0x00FFFFFF'u64)

proc readAccumulator48*(s: var Dsp56300State, isB: bool): uint64 =
  let val = if isB: s.getB() else: s.getA()
  s.updateScalingFlag(val)

  if calcExtensionFlag(val, s.sr):
    s.sr = s.sr or SR_L
    if val.bit55 == 0:
      return CONST_POS_LIMIT48
    else:
      return CONST_NEG_LIMIT48

  let sMode = (s.sr shr 10) and 0x03'u32
  let u = cast[uint64](val)
  case sMode
  of 0: # No scaling
    return u and 0x00FFFFFFFFFFFF'u64
  of 1: # Scale down
    return (u shr 1) and 0x00FFFFFFFFFFFF'u64
  of 2: # Scale up
    return (u shl 1) and 0x00FFFFFFFFFFFF'u64
  else:
    return u and 0x00FFFFFFFFFFFF'u64

# Rounding
proc roundAccumulator*(val: int64, sr: uint32): int64 =
  let sMode = (sr shr 10) and 0x03'u32
  let rm = (sr and SR_RM) != 0 # false: convergent, true: two's-complement
  let roundBitPos = case sMode
    of 0: 23
    of 1: 24
    of 2: 22
    else: 23

  let u = cast[uint64](val)
  let halfVal = 1'u64 shl roundBitPos
  let maskLower = (1'u64 shl (roundBitPos + 1)) - 1
  let lowerBits = u and maskLower
  let bitAtRound = (u shr (roundBitPos + 1)) and 1'u64

  var roundUp = false
  if not rm:
    # Convergent rounding
    if lowerBits > halfVal:
      roundUp = true
    elif lowerBits == halfVal:
      roundUp = (bitAtRound == 1'u64) # round to nearest even
  else:
    # Two's-complement rounding
    if lowerBits >= halfVal:
      roundUp = true

  var res = if roundUp: u + (1'u64 shl (roundBitPos + 1)) else: u
  # Clear lower bits
  res = res and not maskLower
  return signExtend56(res)

# ---------------------------------------------------------------------------
# Data ALU Core Instructions
# ---------------------------------------------------------------------------

proc aluAdd*(s: var Dsp56300State, src: int64, isDstB: bool, withCarry: bool = false) =
  let dst = if isDstB: s.getB() else: s.getA()
  let cIn = if withCarry and ((s.sr and SR_C) != 0): 1'i64 else: 0'i64

  let rawDst = cast[uint64](dst) and 0x00FFFFFFFFFFFFFF'u64
  let rawSrc = cast[uint64](src) and 0x00FFFFFFFFFFFFFF'u64
  let rawSum = rawDst + rawSrc + uint64(cIn)

  let cOut = (rawSum and (1'u64 shl 56)) != 0
  var res = signExtend56(rawSum)

  # Overflow check: sign of inputs same, but sign of result different
  let signDst = dst.bit55
  let signSrc = src.bit55
  let signRes = res.bit55
  let v = (signDst == signSrc) and (signDst != signRes)

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, v or sat)

proc aluSub*(s: var Dsp56300State, src: int64, isDstB: bool, withBorrow: bool = false) =
  let dst = if isDstB: s.getB() else: s.getA()
  let bIn = if withBorrow and ((s.sr and SR_C) != 0): 1'i64 else: 0'i64

  let rawDst = cast[uint64](dst) and 0x00FFFFFFFFFFFFFF'u64
  let rawSrc = cast[uint64](src) and 0x00FFFFFFFFFFFFFF'u64
  let rawDiff = (rawDst - rawSrc - uint64(bIn)) and 0x00FFFFFFFFFFFFFF'u64

  let cOut = rawDst < (rawSrc + uint64(bIn)) # Borrow
  var res = signExtend56(rawDiff)

  let signDst = dst.bit55
  let signSrc = src.bit55
  let signRes = res.bit55
  let v = (signDst != signSrc) and (signDst != signRes)

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, v or sat)

proc aluCmp*(s: var Dsp56300State, s1: int64, isDstB: bool) =
  # S2 - S1 (destination accumulator unchanged)
  let s2 = if isDstB: s.getB() else: s.getA()
  let rawS2 = cast[uint64](s2) and 0x00FFFFFFFFFFFFFF'u64
  let rawS1 = cast[uint64](s1) and 0x00FFFFFFFFFFFFFF'u64
  let rawDiff = (rawS2 - rawS1) and 0x00FFFFFFFFFFFFFF'u64

  let cOut = rawS2 < rawS1
  let res = signExtend56(rawDiff)

  let signS2 = s2.bit55
  let signS1 = s1.bit55
  let signRes = res.bit55
  let v = (signS2 != signS1) and (signS2 != signRes)

  s.updateArithmeticCcr(res, cOut, v)

proc aluCmpm*(s: var Dsp56300State, s1: int64, isDstB: bool) =
  # |S2| - |S1|
  let s2 = if isDstB: s.getB() else: s.getA()
  let absS2 = if s2 < 0: -s2 else: s2
  let absS1 = if s1 < 0: -s1 else: s1

  let rawS2 = cast[uint64](absS2) and 0x00FFFFFFFFFFFFFF'u64
  let rawS1 = cast[uint64](absS1) and 0x00FFFFFFFFFFFFFF'u64
  let rawDiff = (rawS2 - rawS1) and 0x00FFFFFFFFFFFFFF'u64

  let cOut = rawS2 < rawS1
  let res = signExtend56(rawDiff)
  let v = false

  s.updateArithmeticCcr(res, cOut, v)

# Fractional Multiplication Helpers (24x24 -> 48 bits, left-shifted 1 bit)
proc multFractional24*(s1: int32, s2: int32): int64 =
  # Inputs are signed 24-bit fractions (int32 in range -8388608..8388607)
  let p = int64(s1) * int64(s2)
  # Left shift 1 bit for fractional alignment
  let pFrac = p shl 1
  return signExtend56(cast[uint64](pFrac))

proc aluMpy*(s: var Dsp56300State, s1: int32, s2: int32, isDstB: bool, negate: bool = false, round: bool = false) =
  var p = multFractional24(s1, s2)
  if negate:
    p = -p
  if round:
    p = roundAccumulator(p, s.sr)

  var sat = false
  p = applyArithmeticSaturation(p, s.sr, sat)

  if isDstB: s.setB(p) else: s.setA(p)
  s.updateArithmeticCcr(p, false, sat)

proc aluMac*(s: var Dsp56300State, s1: int32, s2: int32, isDstB: bool, negate: bool = false, round: bool = false) =
  let dst = if isDstB: s.getB() else: s.getA()
  var p = multFractional24(s1, s2)
  if negate:
    p = -p

  let rawDst = cast[uint64](dst) and 0x00FFFFFFFFFFFFFF'u64
  let rawP = cast[uint64](p) and 0x00FFFFFFFFFFFFFF'u64
  let rawSum = rawDst + rawP

  let cOut = (rawSum and (1'u64 shl 56)) != 0
  var res = signExtend56(rawSum)

  let signDst = dst.bit55
  let signP = p.bit55
  let signRes = res.bit55
  let v = (signDst == signP) and (signDst != signRes)

  if round:
    res = roundAccumulator(res, s.sr)

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, v or sat)

proc aluMpySu*(s: var Dsp56300State, s1: uint32, s2: uint32, isDstB: bool, s1Signed: bool, s2Signed: bool) =
  let v1 = if s1Signed: int64(signExtend24(s1)) else: int64(s1 and 0x00FFFFFF'u32)
  let v2 = if s2Signed: int64(signExtend24(s2)) else: int64(s2 and 0x00FFFFFF'u32)
  let p = (v1 * v2) shl 1
  let res = signExtend56(cast[uint64](p))

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, false, false)

proc aluMacSu*(s: var Dsp56300State, s1: uint32, s2: uint32, isDstB: bool, s1Signed: bool, s2Signed: bool) =
  let dst = if isDstB: s.getB() else: s.getA()
  let v1 = if s1Signed: int64(signExtend24(s1)) else: int64(s1 and 0x00FFFFFF'u32)
  let v2 = if s2Signed: int64(signExtend24(s2)) else: int64(s2 and 0x00FFFFFF'u32)
  let p = signExtend56(cast[uint64]((v1 * v2) shl 1))

  let rawDst = cast[uint64](dst) and 0x00FFFFFFFFFFFFFF'u64
  let rawP = cast[uint64](p) and 0x00FFFFFFFFFFFFFF'u64
  let rawSum = rawDst + rawP

  let cOut = (rawSum and (1'u64 shl 56)) != 0
  let res = signExtend56(rawSum)

  let signDst = dst.bit55
  let signP = p.bit55
  let signRes = res.bit55
  let v = (signDst == signP) and (signDst != signRes)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, v)

proc aluDmac*(s: var Dsp56300State, s1: uint32, s2: uint32, isDstB: bool, s1Signed: bool, s2Signed: bool, negate: bool = false) =
  # [D -> 24] +- S1 * S2 -> D
  let dst = if isDstB: s.getB() else: s.getA()
  let shiftedDst = dst shr 24 # 24-bit arithmetic right shift

  let v1 = if s1Signed: int64(signExtend24(s1)) else: int64(s1 and 0x00FFFFFF'u32)
  let v2 = if s2Signed: int64(signExtend24(s2)) else: int64(s2 and 0x00FFFFFF'u32)
  var p = signExtend56(cast[uint64]((v1 * v2) shl 1))
  if negate:
    p = -p

  let rawDst = cast[uint64](shiftedDst) and 0x00FFFFFFFFFFFFFF'u64
  let rawP = cast[uint64](p) and 0x00FFFFFFFFFFFFFF'u64
  let rawSum = rawDst + rawP

  let cOut = (rawSum and (1'u64 shl 56)) != 0
  let res = signExtend56(rawSum)

  let signDst = shiftedDst.bit55
  let signP = p.bit55
  let signRes = res.bit55
  let v = (signDst == signP) and (signDst != signRes)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, v)

# Shifting & Rotation
proc aluAsl*(s: var Dsp56300State, isDstB: bool, shiftCount: int = 1) =
  var val = if isDstB: s.getB() else: s.getA()
  var cOut = false
  var vOut = false

  for _ in 1..shiftCount:
    let oldSign = val.bit55
    cOut = (val.bit55 != 0)
    val = signExtend56((cast[uint64](val) shl 1) and 0x00FFFFFFFFFFFFFF'u64)
    if val.bit55 != oldSign:
      vOut = true

  if isDstB: s.setB(val) else: s.setA(val)
  s.updateArithmeticCcr(val, cOut, vOut)

proc aluAsr*(s: var Dsp56300State, isDstB: bool, shiftCount: int = 1) =
  var val = if isDstB: s.getB() else: s.getA()
  var cOut = false

  for _ in 1..shiftCount:
    cOut = (val.bit(0) != 0)
    let signBit = uint64(val.bit55) shl 55
    val = signExtend56(((cast[uint64](val) and 0x00FFFFFFFFFFFFFF'u64) shr 1) or signBit)

  if isDstB: s.setB(val) else: s.setA(val)
  s.updateArithmeticCcr(val, cOut, false)

proc aluLsl*(s: var Dsp56300State, isDstB: bool, shiftCount: int = 1) =
  var val = if isDstB: s.getB() else: s.getA()
  var cOut = false

  for _ in 1..shiftCount:
    cOut = (val.bit55 != 0)
    val = signExtend56((cast[uint64](val) shl 1) and 0x00FFFFFFFFFFFFFF'u64)

  if isDstB: s.setB(val) else: s.setA(val)
  s.updateArithmeticCcr(val, cOut, false)

proc aluLsr*(s: var Dsp56300State, isDstB: bool, shiftCount: int = 1) =
  var val = if isDstB: s.getB() else: s.getA()
  var cOut = false

  for _ in 1..shiftCount:
    cOut = (val.bit(0) != 0)
    val = signExtend56((cast[uint64](val) and 0x00FFFFFFFFFFFFFF'u64) shr 1)

  if isDstB: s.setB(val) else: s.setA(val)
  s.updateArithmeticCcr(val, cOut, false)

proc aluRol*(s: var Dsp56300State, isDstB: bool) =
  let val = if isDstB: s.getB() else: s.getA()
  let cIn = uint64(if (s.sr and SR_C) != 0: 1 else: 0)
  let cOut = (val.bit55 != 0)
  let res = signExtend56(((cast[uint64](val) shl 1) and 0x00FFFFFFFFFFFFFF'u64) or cIn)

  let oldSign = val.bit55
  let vOut = (res.bit55 != oldSign)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, vOut)

proc aluRor*(s: var Dsp56300State, isDstB: bool) =
  let val = if isDstB: s.getB() else: s.getA()
  let cIn = uint64(if (s.sr and SR_C) != 0: 1 else: 0) shl 55
  let cOut = (val.bit(0) != 0)
  let res = signExtend56(((cast[uint64](val) and 0x00FFFFFFFFFFFFFF'u64) shr 1) or cIn)

  let oldSign = val.bit55
  let vOut = (res.bit55 != oldSign)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, cOut, vOut)

proc aluNorm*(s: var Dsp56300State, rIdx: int, isDstB: bool) =
  # If E . not(U) . not(Z) = 1 then ASL D and Rn-1 -> Rn
  # else if E = 1 then ASR D and Rn+1 -> Rn
  # else NOP
  let e = (s.sr and SR_E) != 0
  let u = (s.sr and SR_U) != 0
  let z = (s.sr and SR_Z) != 0

  if e and (not u) and (not z):
    s.aluAsl(isDstB, 1)
    s.r[rIdx] = mask24(s.r[rIdx] - 1)
  elif e:
    s.aluAsr(isDstB, 1)
    s.r[rIdx] = mask24(s.r[rIdx] + 1)

proc aluDiv*(s: var Dsp56300State, s24: uint32, isDstB: bool) =
  # Nonrestoring division step (DSP56300FM Section 13, page 13-52)
  var d = if isDstB: s.getB() else: s.getA()
  let sSign = (s24 shr 23) and 1'u32
  let dSign = d.bit55
  let signDiff = (dSign xor sSign) != 0

  # 1. Shift D left 1 bit, move C into LSB
  let oldSign = d.bit55
  let cIn = uint64(if (s.sr and SR_C) != 0: 1 else: 0)
  var shiftedD = ((cast[uint64](d) and 0x00FFFFFFFFFFFFFF'u64) shl 1) or cIn
  shiftedD = shiftedD and 0x00FFFFFFFFFFFFFF'u64

  # 2. Add or subtract divisor from MSP (sign-extended to 56 bits)
  let sVal = int64(signExtend24(s24)) shl 24 # placed at MSP
  let rawS = cast[uint64](sVal) and 0x00FFFFFFFFFFFFFF'u64

  var rawRes: uint64
  if signDiff:
    rawRes = (shiftedD + rawS) and 0x00FFFFFFFFFFFFFF'u64
  else:
    rawRes = (shiftedD - rawS) and 0x00FFFFFFFFFFFFFF'u64

  let res = signExtend56(rawRes)
  let v = (res.bit55 != oldSign)
  let c = (res.bit55 == 0) # C set if bit 55 of result is cleared

  if isDstB: s.setB(res) else: s.setA(res)

  # Update CCR for DIV: only L, V, C affected
  var ccr = s.sr and not (SR_C or SR_V)
  if c: ccr = ccr or SR_C
  if v: ccr = ccr or SR_V or SR_L
  s.sr = ccr

proc aluMax*(s: var Dsp56300State, isSrcB: bool) =
  # If B - A <= 0 then A -> B (or opposite if A is destination)
  # C cleared if transfer performed, set otherwise
  let aVal = s.getA()
  let bVal = s.getB()
  if (bVal - aVal) <= 0:
    s.setB(aVal)
    s.sr = s.sr and not SR_C
  else:
    s.sr = s.sr or SR_C

proc aluMaxm*(s: var Dsp56300State, isSrcB: bool) =
  # If |B| - |A| <= 0 then A -> B
  let aVal = s.getA()
  let bVal = s.getB()
  let absA = if aVal < 0: -aVal else: aVal
  let absB = if bVal < 0: -bVal else: bVal
  if (absB - absA) <= 0:
    s.setB(aVal)
    s.sr = s.sr and not SR_C
  else:
    s.sr = s.sr or SR_C

proc aluAbs*(s: var Dsp56300State, isDstB: bool) =
  let val = if isDstB: s.getB() else: s.getA()
  var res = if val < 0: -val else: val
  let v = (val == CONST_NEG_SAT48) # Overflow if negating most negative number

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, false, v or sat)

proc aluNeg*(s: var Dsp56300State, isDstB: bool) =
  let val = if isDstB: s.getB() else: s.getA()
  var res = signExtend56((cast[uint64](0) - cast[uint64](val)) and 0x00FFFFFFFFFFFFFF'u64)
  let v = (val == CONST_NEG_SAT48)
  let c = (val != 0)

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, c, v or sat)

proc aluNot*(s: var Dsp56300State, isDstB: bool) =
  # Inverts bits 47..24 (MSP)
  let val = if isDstB: s.getB() else: s.getA()
  let u = cast[uint64](val)
  let invMsp = (u xor 0x0000FFFFFF000000'u64) and 0x00FFFFFFFFFFFFFF'u64
  let res = signExtend56(invMsp)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateLogicalCcr(res)

proc aluAnd*(s: var Dsp56300State, src24: uint32, isDstB: bool) =
  # AND source with MSP (bits 47..24)
  let val = if isDstB: s.getB() else: s.getA()
  let u = cast[uint64](val)
  let mask = (uint64(src24 and 0x00FFFFFF'u32) shl 24) or 0x00FF000000FFFFFF'u64
  let res = signExtend56(u and mask)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateLogicalCcr(res)

proc aluOr*(s: var Dsp56300State, src24: uint32, isDstB: bool) =
  # OR source with MSP (bits 47..24)
  let val = if isDstB: s.getB() else: s.getA()
  let u = cast[uint64](val)
  let mask = uint64(src24 and 0x00FFFFFF'u32) shl 24
  let res = signExtend56(u or mask)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateLogicalCcr(res)

proc aluEor*(s: var Dsp56300State, src24: uint32, isDstB: bool) =
  # EOR source with MSP (bits 47..24)
  let val = if isDstB: s.getB() else: s.getA()
  let u = cast[uint64](val)
  let mask = uint64(src24 and 0x00FFFFFF'u32) shl 24
  let res = signExtend56(u xor mask)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateLogicalCcr(res)

proc aluRnd*(s: var Dsp56300State, isDstB: bool) =
  let val = if isDstB: s.getB() else: s.getA()
  var res = roundAccumulator(val, s.sr)

  var sat = false
  res = applyArithmeticSaturation(res, s.sr, sat)

  if isDstB: s.setB(res) else: s.setA(res)
  s.updateArithmeticCcr(res, false, sat)

proc aluClb*(s: var Dsp56300State, isSrcB: bool, isDstB: bool) =
  # Count leading bits: 9 - (number of consecutive leading zeros/ones)
  let sVal = if isSrcB: s.getB() else: s.getA()
  let u = cast[uint64](sVal) and 0x00FFFFFFFFFFFFFF'u64
  let sign = (u shr 55) and 1'u64

  var count = 0
  for i in countdown(55, 0):
    if ((u shr i) and 1'u64) == sign:
      count.inc
    else:
      break

  var resInt: int32
  if u == 0:
    resInt = 0
  else:
    resInt = 9 - int32(count)

  let resWord = uint32(resInt) and 0x00FFFFFF'u32
  let finalVal = signExtend56(uint64(resWord) shl 24)

  if isDstB: s.setB(finalVal) else: s.setA(finalVal)

  var ccr = s.sr and not (SR_N or SR_Z or SR_V)
  if resInt < 0:
    ccr = ccr or SR_N
  if resInt == 0:
    ccr = ccr or SR_Z
  s.sr = ccr

proc aluClr*(s: var Dsp56300State, isDstB: bool) =
  if isDstB: s.setB(0) else: s.setA(0)
  s.updateArithmeticCcr(0, false, false)

proc aluTfr*(s: var Dsp56300State, src: int64, isDstB: bool) =
  if isDstB: s.setB(src) else: s.setA(src)
  s.updateArithmeticCcr(src, false, false)
