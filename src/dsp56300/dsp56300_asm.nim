## Motorola DSP56300 Command-Line Assembler
## Assembles Motorola DSP56300 .asm text files into 24-bit machine code words or binary.

import std/[os, strutils, parseopt, parseutils, tables]
import dsp56300/asm_parser

proc printHelp() =
  echo "Motorola DSP56300 / DSP56311 Assembler (dsp56300_asm)"
  echo "Usage: dsp56300_asm <input.asm> [options]"
  echo ""
  echo "Options:"
  echo "  -o, --out:<file>         Output file (default: stdout or <input>.words)"
  echo "  -f, --format:<bin|hex>   Output format ('hex' lines or raw 24-bit 'bin' big-endian)"
  echo "  -b, --base:<addr>        Base P-RAM origin address (default: $100 or from ORG)"
  echo "  -v, --verbose            Print symbol table and memory layout"
  echo "  -h, --help               Show this help message"

proc main() =
  var inputFile = ""
  var outputFile = ""
  var format = "hex"
  var baseOrg: uint32 = 0x100'u32
  var verbose = false

  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if inputFile.len == 0:
        inputFile = key
      else:
        outputFile = key
    of cmdLongOption, cmdShortOption:
      case key.toLowerAscii()
      of "o", "out":
        outputFile = val
      of "f", "format":
        format = val.toLowerAscii()
      of "b", "base":
        var h = 0
        if val.startsWith("$"):
          discard parseHex(val[1 ..^ 1], h)
        elif val.startsWith("0x") or val.startsWith("0X"):
          discard parseHex(val[2 ..^ 1], h)
        else:
          h = parseInt(val)
        baseOrg = uint32(h)
      of "v", "verbose":
        verbose = true
      of "h", "help":
        printHelp()
        quit(0)
      else:
        echo "Unknown option: --", key
        quit(1)
    of cmdEnd:
      break

  if inputFile.len == 0:
    printHelp()
    quit(1)

  if not fileExists(inputFile):
    echo "Error: Input file does not exist: ", inputFile
    quit(1)

  let res = assembleFile(inputFile, baseOrg)

  if verbose:
    echo "--- Symbol Table ---"
    for k, v in res.symbols:
      echo "  ", k, " = $", v.toHex(4)
    echo "--- P-RAM Words (", res.pRam.len, ") ---"
    for e in res.pRam:
      echo "  P:$", e.address.toHex(4), "  ", e.word.toHex(6)

  if outputFile.len > 0:
    if format == "bin":
      var binData = newString(res.pRam.len * 3)
      for i, e in res.pRam:
        let w = e.word
        binData[i * 3 + 0] = char((w shr 16) and 0xFF)
        binData[i * 3 + 1] = char((w shr 8) and 0xFF)
        binData[i * 3 + 2] = char(w and 0xFF)
      writeFile(outputFile, binData)
    else:
      var hexLines: seq[string] = @[]
      for e in res.pRam:
        hexLines.add(e.word.toHex(6))
      writeFile(outputFile, hexLines.join("\n") & "\n")
    echo "Assembled ", res.pRam.len, " words to ", outputFile
  elif not verbose:
    for e in res.pRam:
      echo "P:$", e.address.toHex(4), ": ", e.word.toHex(6)

when isMainModule:
  main()
