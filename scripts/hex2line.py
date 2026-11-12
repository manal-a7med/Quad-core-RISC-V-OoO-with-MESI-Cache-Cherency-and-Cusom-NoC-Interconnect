#!/usr/bin/env python3
"""Convert a one-32-bit-word-per-line hex file into the 256-bit line format
used by rtl/memory/main_memory.v (word 0 in the low bits of each line).
Usage: hex2line.py in.hex out.hex"""
import sys
words = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("//")]
words += ["00000000"] * (-len(words) % 8)
with open(sys.argv[2], "w") as f:
    for i in range(0, len(words), 8):
        f.write("".join(reversed(words[i:i + 8])) + "\n")
