#!/usr/bin/env python3
"""power_summary.py REPDIR -- table of the vectorless (synthesis) power estimate from
sta.rpt and the activity-based power of the whole run and the 64-cycle windows."""
import re
import sys

rep = sys.argv[1]


def totals(text):
    """Group rows of an OpenSTA report_power table, in uW."""
    out = {}
    for g in ('Sequential', 'Combinational', 'Total'):
        m = re.search(rf'^{g}\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)', text, re.M)
        if m:
            out[g] = [float(x) * 1e6 for x in m.groups()]
    return out


rows = [('synthesis estimate (vectorless, activity 0.1)', totals(open(f'{rep}/sta.rpt').read()))]
for blk in re.split(r'^== power ', open(f'{rep}/power.rpt').read(), flags=re.M)[1:]:
    rows.append((blk.splitlines()[0].split(', VCD')[0], totals(blk)))
print(f"{'case':50s} {'internal':>9s} {'switching':>9s} {'leakage':>9s} {'total uW':>9s}")
for name, t in rows:
    if 'Total' in t:
        i, s, l, tot = t['Total']
        print(f"{name[:50]:50s} {i:9.2f} {s:9.2f} {l:9.2f} {tot:9.2f}")
