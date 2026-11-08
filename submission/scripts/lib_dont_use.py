#!/usr/bin/env python3
"""lib_dont_use.py IN OUT CELL... -- copy a Liberty file and add `dont_use : true;`
to the listed cells (shell-style wildcards allowed). The copy is used only for
technology mapping (Yosys/ABC); timing, power and the Resizer use the original
library. Purpose: keep ABC away from cells with three- or four-high transistor
stacks, which are very slow at the slow corner (0.3-0.5 ns each)."""
import fnmatch
import re
import sys

src, dst, pats = sys.argv[1], sys.argv[2], sys.argv[3:]
out, n = [], 0
for line in open(src):
    out.append(line)
    m = re.match(r'\s*cell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{', line)
    if m and any(fnmatch.fnmatch(m.group(1), p) for p in pats):
        out.append('    dont_use : true ;\n')
        n += 1
open(dst, 'w').writelines(out)
print(f'lib_dont_use: {n} cells marked dont_use -> {dst}')
