# Clean-room MIT implementation of Motorola DSP56300 Hardware Loop Engine
# Hardware Reference: DSP56300FM Chapter 5 (Section 5.4.4), Chapter 12, Chapter 13

import state

proc doStart*(
    s: var Dsp56300State, count: uint32, endAddr: uint32, firstInstPc: uint32
) =
  # 1. First cycle: Push current LA and LC
  s.stackPush(s.la, s.lc)

  # 2. Second cycle: Push first instruction PC of loop and current SR
  s.stackPush(firstInstPc, s.sr)

  # 3. Setup loop parameters
  s.la = mask24(endAddr - 1'u32)
  s.lc = mask24(count)

  # 4. Set Loop Flag (LF)
  s.sr = s.sr or SR_LF

  # Special case: initial count 0
  let scMode = (s.sr and SR_SC) != 0
  if count == 0:
    if not scMode:
      # In normal mode, count 0 skips loop body immediately
      var dummySsh, dummySsl: uint32
      s.stackPop(dummySsh, dummySsl) # Pop PC/SR
      s.sr = dummySsl
      s.stackPop(s.la, s.lc) # Pop LA/LC
      s.pc = mask24(endAddr)
    else:
      # In 16-bit compatibility mode, 0 means 65536 iterations
      s.lc = 65536'u32

proc doForeverStart*(s: var Dsp56300State, endAddr: uint32, firstInstPc: uint32) =
  s.stackPush(s.la, s.lc)
  s.stackPush(firstInstPc, s.sr)

  s.la = mask24(endAddr - 1'u32)
  # LC is pushed but not overwritten by DO FOREVER
  s.sr = s.sr or SR_LF or SR_FV

proc enddo*(s: var Dsp56300State) =
  # Restore SR from SSL, pop stack
  var popSsh, popSsl: uint32
  s.stackPop(popSsh, popSsl)
  s.sr = popSsl

  # Restore LA and LC from SSH and SSL, pop stack
  s.stackPop(s.la, s.lc)

proc breakLoop*(s: var Dsp56300State, exitAddr: uint32) =
  s.enddo()
  s.pc = mask24(exitAddr)

proc repStart*(s: var Dsp56300State, count: uint32) =
  s.repActive = true
  s.repCount = count
  s.lc = mask24(count)

proc checkEndOfLoop*(s: var Dsp56300State, currentInstPc: uint32) =
  # Check if we just executed the last instruction of a hardware DO loop
  if (s.sr and SR_LF) != 0 and currentInstPc == s.la:
    let isForever = (s.sr and SR_FV) != 0
    let topStackIdx = (int(s.sp and SP_CTR_MASK) - 1) and 0x0F
    let loopStartPc = s.ssh[topStackIdx]

    if isForever:
      # DO FOREVER: loop again indefinitely, decrement LC without testing
      s.lc = mask24(s.lc - 1'u32)
      s.pc = loopStartPc
    else:
      if s.lc > 1'u32:
        # Loop again
        s.lc = s.lc - 1'u32
        s.pc = loopStartPc
      else:
        # Loop finished normally (LC == 1)
        let loopEndLa = s.la
        var popSsh, popSsl: uint32
        # Pop PC and SR
        s.stackPop(popSsh, popSsl)
        s.sr = popSsl # Restores SR (clearing LF and FV)
        # Pop LA and LC
        s.stackPop(s.la, s.lc)
        # Advance PC past loop body
        s.pc = mask24(loopEndLa + 1'u32)
