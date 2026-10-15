## Motorola DSP56300 Canonical Assembler Module
## Re-exports asm_parser and provides high-level assemble functions.

import dsp56300/asm_parser
export asm_parser

proc assembleDsp56300*(text: string, baseOrg: uint32 = 0): seq[uint32] =
  ## Parses and assembles DSP56300 assembly text into a sequence of 24-bit binary words.
  assembleText(text, baseOrg).binaryWords

proc assembleDsp56300File*(path: string, baseOrg: uint32 = 0): seq[uint32] =
  ## Reads and assembles a DSP56300 .asm file into a sequence of 24-bit binary words.
  assembleFile(path, baseOrg).binaryWords
