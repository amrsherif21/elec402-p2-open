#!/usr/bin/env python3
"""vcd_events.py VCD SIGNAL -- print the times (ps) at which a 1-bit signal rises/falls."""
import sys
vcd, sig = sys.argv[1], sys.argv[2]
code, t, last = None, 0, None
with open(vcd) as f:
    for line in f:
        if line.startswith('$var') and line.split()[4] == sig and code is None:
            code = line.split()[3]
        elif line.startswith('#'):
            t = int(line[1:])
        elif code and len(line) > 1 and line[0] in '01xz' and line[1:].strip() == code:
            v = line[0]
            if v != last:
                print(t, v)
            last = v
