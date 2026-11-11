#!/usr/bin/env python3
"""Check a program's UART output: every line of expect.txt must appear, in
order, as a whole line (or the start of a line) of the simulation log.
Usage: check_uart.py expect.txt run.log"""
import sys
expect = [l.rstrip("\r\n") for l in open(sys.argv[1]) if l.strip()]
log = [l.rstrip("\r\n").replace("\r", "") for l in open(sys.argv[2])]
i = 0
for line in log:
    if i < len(expect) and line.startswith(expect[i]):
        i += 1
if i < len(expect):
    print(f"check_uart: missing or out of order: {expect[i]!r}")
    sys.exit(1)
print(f"check_uart: {len(expect)} expected lines found")
