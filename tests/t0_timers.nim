# Tier T0 Unit Tests for Motorola DSP56311 Triple Timer Module
# Hardware Reference: DSP56311UM Chapter 9, DSP56367UM Table 5-2

import std/unittest
import dsp56300/peripherals/timers

suite "DSP56311 Triple Timer Module":

  test "Reset state matches hardware specification":
    var timers = newTripleTimerModule()
    check timers.readRegister(TIMERS_TPLR) == 0'u32
    check timers.readRegister(TIMERS_TPCR) == 0'u32
    for t in 0..2:
      check timers.readRegister(tcsrAddress(t)) == 0'u32
      check timers.readRegister(tcprAddress(t)) == 0'u32
      check timers.readRegister(tcrAddress(t)) == 0'u32
      check not timers.isDmaRequestAsserted(t)
      check not timers.isCompareInterruptAsserted(t)
      check not timers.isOverflowInterruptAsserted(t)

  test "Timer 0 Mode 0 compare match and reload (TRM=1)":
    var timers = newTripleTimerModule()
    
    # Configure Timer 0:
    # TLR0 = 10, TCPR0 = 15
    # TRM = 1 (bit 9), TCIE = 1 (bit 2), TE = 1 (bit 0)
    timers.writeRegister(tlrAddress(0), 10'u32)
    timers.writeRegister(tcprAddress(0), 15'u32)
    
    # TCSR = (1 shl 9) [TRM] or (1 shl 2) [TCIE] or 1 [TE] = 0x000205
    let tcsrVal = (1'u32 shl 9) or (1'u32 shl 2) or 1'u32
    timers.writeRegister(tcsrAddress(0), tcsrVal)

    # Initial tick loads TLR = 10
    timers.step(1)
    check timers.readRegister(tcrAddress(0)) == 10'u32
    check not timers.isDmaRequestAsserted(0)
    check not timers.isCompareInterruptAsserted(0)

    # Step 5 more ticks: 11, 12, 13, 14, 15
    timers.step(5)
    check timers.readRegister(tcrAddress(0)) == 15'u32
    
    # At compare match: TCF (bit 21) set, compare interrupt asserted, DMA DRS 18 asserted
    check (timers.readRegister(tcsrAddress(0)) and TCSR_TCF) != 0
    check timers.isCompareInterruptAsserted(0)
    check timers.isDmaRequestAsserted(0)

    # Next tick reloads TLR (10) because TRM=1
    timers.step(1)
    check timers.readRegister(tcrAddress(0)) == 10'u32

    # Clear TCF by writing 1 to bit 21 of TCSR
    timers.writeRegister(tcsrAddress(0), tcsrVal or TCSR_TCF)
    check (timers.readRegister(tcsrAddress(0)) and TCSR_TCF) == 0
    check not timers.isCompareInterruptAsserted(0)
    check not timers.isDmaRequestAsserted(0)

  test "Prescaler divide factor (PCE=1, TPLR PL=3 -> div by 4)":
    var timers = newTripleTimerModule()

    # Prescaler preload = 3 (divide by 4)
    # TPLR = 3
    timers.writeRegister(TIMERS_TPLR, 3'u32)

    # Timer 1: PCE=1 (bit 15), TE=1 (bit 0), Mode 0
    timers.writeRegister(tlrAddress(1), 0'u32)
    timers.writeRegister(tcprAddress(1), 100'u32)
    let tcsrVal = (1'u32 shl 15) or 1'u32
    timers.writeRegister(tcsrAddress(1), tcsrVal)

    # 4 system clocks -> 1st prescaler tick -> loads TLR (0)
    timers.step(4)
    check timers.readRegister(tcrAddress(1)) == 0'u32

    # 4 more system clocks -> 2nd prescaler tick -> increments to 1
    timers.step(4)
    check timers.readRegister(tcrAddress(1)) == 1'u32

    # 8 more system clocks -> 2 prescaler ticks -> increments to 3
    timers.step(8)
    check timers.readRegister(tcrAddress(1)) == 3'u32

  test "DMA Request Line mapping (Timers 0..2 -> DRS 18..20)":
    var timers = newTripleTimerModule()

    for t in 0..2:
      timers.writeRegister(tlrAddress(t), 0'u32)
      timers.writeRegister(tcprAddress(t), 1'u32)
      timers.writeRegister(tcsrAddress(t), (1'u32 shl 9) or 1'u32) # TRM=1, TE=1
      timers.step(2) # 0, 1 -> match!
      check timers.isDmaRequestAsserted(t)
      check timers.dmaRequestSource(t) == 18 + t
