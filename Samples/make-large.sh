#!/bin/bash
# Writes a ~30 MB log and a ~1.5 MB Swift file next to this script, for the large-file checks.
set -euo pipefail
cd "$(dirname "$0")"
python3 -c '
line = "2026-11-17T08:00:00Z INFO request id=%08d path=/api/items status=200 duration=12ms\n"
with open("large.log", "w") as f:
    for i in range(380000):
        f.write(line % i)
with open("medium.swift", "w") as f:
    for i in range(18000):
        f.write("func value%d(_ x: Int) -> String { return \"v\" + String(x * %d) } // generated\n" % (i, i))
'
ls -la large.log medium.swift
