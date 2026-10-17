# DSP56311 Triple Timer Module
# Hardware Reference: DSP56311UM Chapter 9, DSP56367UM Table 5-2

type
  TimerUnit* = object
    tcsr*: uint32
    tlr*: uint32
    tcpr*: uint32
    tcr*: uint32
    justEnabled*: bool

  TripleTimerModule* = object
    tplr*: uint32
    tpcr*: uint32
    timers*: array[3, TimerUnit]

const
  TIMERS_TPCR* = 0xFFFF82'u32
  TIMERS_TPLR* = 0xFFFF83'u32

  TCSR_TE*   = 1'u32 shl 0
  TCSR_TOIE* = 1'u32 shl 1
  TCSR_TCIE* = 1'u32 shl 2
  TCSR_TC_MASK* = 0x0F'u32 shl 4
  TCSR_INV*  = 1'u32 shl 8
  TCSR_TRM*  = 1'u32 shl 9
  TCSR_DIR*  = 1'u32 shl 11
  TCSR_DI*   = 1'u32 shl 12
  TCSR_DO*   = 1'u32 shl 13
  TCSR_PCE*  = 1'u32 shl 15
  TCSR_TOF*  = 1'u32 shl 20
  TCSR_TCF*  = 1'u32 shl 21

  TPLR_PL_MASK* = 0x001FFFFF'u32

proc tcsrAddress*(t: int): uint32 =
  0xFFFF8F'u32 - uint32(t * 4)

proc tlrAddress*(t: int): uint32 =
  0xFFFF8E'u32 - uint32(t * 4)

proc tcprAddress*(t: int): uint32 =
  0xFFFF8D'u32 - uint32(t * 4)

proc tcrAddress*(t: int): uint32 =
  0xFFFF8C'u32 - uint32(t * 4)

proc dmaRequestSource*(t: int): int =
  18 + t

proc dmaRequestSource*(self: TripleTimerModule, t: int): int =
  18 + t

proc reset*(self: var TripleTimerModule) =
  self.tplr = 0'u32
  self.tpcr = 0'u32
  for t in 0..2:
    self.timers[t].tcsr = 0'u32
    self.timers[t].tlr = 0'u32
    self.timers[t].tcpr = 0'u32
    self.timers[t].tcr = 0'u32
    self.timers[t].justEnabled = false

proc newTripleTimerModule*(): TripleTimerModule =
  result.reset()

proc isDmaRequestAsserted*(self: TripleTimerModule, t: int): bool =
  (self.timers[t].tcsr and TCSR_TCF) != 0

proc isCompareInterruptAsserted*(self: TripleTimerModule, t: int): bool =
  let tcsr = self.timers[t].tcsr
  ((tcsr and TCSR_TCF) != 0) and ((tcsr and TCSR_TCIE) != 0)

proc isOverflowInterruptAsserted*(self: TripleTimerModule, t: int): bool =
  let tcsr = self.timers[t].tcsr
  ((tcsr and TCSR_TOF) != 0) and ((tcsr and TCSR_TOIE) != 0)

proc readRegister*(self: TripleTimerModule, a: uint32): uint32 =
  case a
  of TIMERS_TPCR:
    result = self.tpcr
  of TIMERS_TPLR:
    result = self.tplr
  else:
    for t in 0..2:
      if a == tcsrAddress(t):
        return self.timers[t].tcsr
      elif a == tlrAddress(t):
        return 0'u32 # TLR is write-only per DSP56311UM section 9.1.2
      elif a == tcprAddress(t):
        return self.timers[t].tcpr
      elif a == tcrAddress(t):
        return self.timers[t].tcr
    result = 0'u32

proc writeRegister*(self: var TripleTimerModule, a: uint32, val: uint32) =
  let v = val and 0x00FFFFFF'u32
  case a
  of TIMERS_TPCR:
    discard # TPCR is read-only
  of TIMERS_TPLR:
    self.tplr = v
    self.tpcr = v and TPLR_PL_MASK # writing TPLR initializes prescaler count
  else:
    for t in 0..2:
      if a == tcsrAddress(t):
        let oldTcsr = self.timers[t].tcsr
        # Bit 21 (TCF) and Bit 20 (TOF) are cleared by writing a 1
        var newTcsr = v and not (TCSR_TCF or TCSR_TOF)
        if (oldTcsr and TCSR_TCF) != 0 and (v and TCSR_TCF) == 0:
          newTcsr = newTcsr or TCSR_TCF # keep TCF if not cleared
        if (oldTcsr and TCSR_TOF) != 0 and (v and TCSR_TOF) == 0:
          newTcsr = newTcsr or TCSR_TOF # keep TOF if not cleared

        # Check TE transition from 0 to 1
        let wasEnabled = (oldTcsr and TCSR_TE) != 0
        let nowEnabled = (newTcsr and TCSR_TE) != 0
        if not wasEnabled and nowEnabled:
          self.timers[t].tcr = 0'u32
          self.timers[t].justEnabled = true
        elif not nowEnabled:
          # Disabling timer clears TCF and TOF
          newTcsr = newTcsr and not (TCSR_TCF or TCSR_TOF)
          self.timers[t].justEnabled = false

        self.timers[t].tcsr = newTcsr
        return
      elif a == tlrAddress(t):
        self.timers[t].tlr = v
        return
      elif a == tcprAddress(t):
        self.timers[t].tcpr = v
        return
      elif a == tcrAddress(t):
        discard # TCR is read-only

proc stepTimer(timer: var TimerUnit) =
  let tcsr = timer.tcsr
  if (tcsr and TCSR_TE) == 0:
    return

  let trm = (tcsr and TCSR_TRM) != 0
  
  if timer.justEnabled:
    timer.justEnabled = false
    timer.tcr = timer.tlr
  else:
    # Check if we were at compare match on previous cycle with TRM=1
    if trm and (timer.tcr == timer.tcpr):
      timer.tcr = timer.tlr
    else:
      let nextCount = timer.tcr + 1'u32
      if nextCount > 0x00FFFFFF'u32:
        timer.tcr = 0'u32
        timer.tcsr = timer.tcsr or TCSR_TOF
      else:
        timer.tcr = nextCount

  if timer.tcr == timer.tcpr:
    timer.tcsr = timer.tcsr or TCSR_TCF

proc step*(self: var TripleTimerModule, clockCycles: int = 1) =
  let anyEnabled = ((self.timers[0].tcsr or self.timers[1].tcsr or self.timers[2].tcsr) and TCSR_TE) != 0
  if not anyEnabled:
    return
  for _ in 0..<clockCycles:
    # 1. Step Prescaler
    var prescalerTick = false
    if self.tpcr > 0:
      dec self.tpcr
    else:
      self.tpcr = self.tplr and TPLR_PL_MASK
      prescalerTick = true

    # 2. Step each timer
    for t in 0..2:
      let tcsr = self.timers[t].tcsr
      if (tcsr and TCSR_TE) == 0:
        continue

      let pce = (tcsr and TCSR_PCE) != 0
      if pce:
        if prescalerTick:
          stepTimer(self.timers[t])
      else:
        # Internal clock (CLK/2) steps each cycle
        stepTimer(self.timers[t])
