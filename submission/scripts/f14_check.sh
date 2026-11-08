#!/usr/bin/env bash
# f14_check.sh NETLIST WORKDIR -- SPEC F14 check on a gate-level netlist: for every
# flip-flop, Yosys' SAT solver proves that its D input is constant whenever RST_N = 0
# (all other inputs and all flip-flop outputs are left free), i.e. that every
# register has a synchronous reset driven by RST_N.
set -euo pipefail
N=$1; W=$2; mkdir -p "$W"; S=$W/$(basename ${N%.v}).f14in.v
python3 - "$N" "$S" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
t = re.sub(r'\\(\S+)(\s)', lambda m: 'e_' + re.sub(r'\W', '_', m.group(1)) + m.group(2), t)
open(sys.argv[2], 'w').write(t)
ds = re.findall(r'\bDFF\w*\s+\S+\s*\(([^;]*)\);', t, re.S)
nets = [re.search(r'\.D\(\s*([^)\s]+)\s*\)', d).group(1) for d in ds]
open(sys.argv[2][:-2] + '.dnets', 'w').write('\n'.join(nets) + '\n')
PY
IMG=openroad/orfs@sha256:d3505fd5f930fcd20d3d25a41f3047230b7db7b7797e3448561c9e556cca3774
docker run --rm -v $PWD:$PWD -w $PWD -e LIB=tech/NangateOpenCellLibrary_slow.lib -e NETLIST=$S -e DNETS=${S%.v}.dnets $IMG \
  /OpenROAD-flow-scripts/tools/install/yosys/bin/yosys -q -l ${S%.f14in.v}.f14.log -c submission/scripts/f14_check.tcl >/dev/null 2>&1
grep F14CHECK ${S%.f14in.v}.f14.log || tail -3 ${S%.f14in.v}.f14.log
