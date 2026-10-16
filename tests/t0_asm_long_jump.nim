import std/[unittest, tables]
import dsp56300/[asm_parser, decode, decode_types, ir, runner]

suite "Motorola DSP56300 Long Jump (> 4096 words) Assembly & Execution":
  test "Assemble long JMP and Jcc (> 0x1000)":
    let source = """
      ORG P:$0000
      NOP
      JMP target_far
      JNE target_far
      JMP target_near
target_near:
      NOP
      ORG P:$1500
target_far:
      NOP
    """
    let res = assembleText(source)
    check res.symbols.hasKey("target_far")
    check res.symbols["target_far"] == 0x1500'u32
    check res.symbols.hasKey("target_near")
    check res.symbols["target_near"] == 6'u32

    # Verify P-memory words
    # P:0 -> NOP (0x000000)
    check res.pRam[0].word == 0x000000'u32

    # P:1,2 -> JMP target_far (2 words: 0x0AF080, 0x001500)
    check res.pRam[1].word == 0x0AF080'u32
    check res.pRam[2].word == 0x001500'u32

    # P:3,4 -> JNE target_far (2 words: 0x0AF0A0 | ccNE, 0x001500)
    check res.pRam[3].word == (0x0AF0A0'u32 or uint32(ord(ConditionCode.ccNE)))
    check res.pRam[4].word == 0x001500'u32

    # P:5 -> JMP target_near (1 word: 0x0C0000 | 6)
    check res.pRam[5].word == (0x0C0000'u32 or 6'u32)

  test "Execute 2-word absolute jump on DSP runner":
    let source = """
      ORG P:$0000
      CLR A
      JMP $1200
      ORG P:$1200
      ADD X0, A
      NOP
    """
    let res = assembleText(source)
    var state = newDspState()
    for entry in res.pRam:
      state.pRam[entry.address] = entry.word

    state.pc = 0'u32
    state.x0 = 0x000042'u32

    # Execute first block at PC 0
    let blk1 = liftBasicBlock(state, 0'u32, maxWords = 10)
    discard runBlock(state, blk1)
    check state.pc == 0x1200'u32

    # Execute target block at PC $1200
    let blk2 = liftBasicBlock(state, 0x1200'u32, maxWords = 10)
    discard runBlock(state, blk2)
    check state.a1 == 0x000042'u32
