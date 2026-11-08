#!/usr/bin/env python3
"""sdf_typmax.py IN OUT -- copy an SDF file, replacing the 'typ' entry of every
(min:typ:max) triple by 'max'. Icarus Verilog annotates the typ value, so this
makes the gate-level simulation use the (setup-pessimistic) maximum delays
computed by OpenSTA, while 'min' is kept unchanged."""
import re, sys
src = open(sys.argv[1]).read()
pat = re.compile(r'\(\s*(-?[0-9.eE+-]+)\s*:\s*(-?[0-9.eE+-]*)\s*:\s*(-?[0-9.eE+-]+)\s*\)')
out, n = pat.subn(lambda m: f'({m.group(1)}:{m.group(3)}:{m.group(3)})', src)
open(sys.argv[2], 'w').write(out)
print(f'sdf_typmax: {n} delay triples set to typ = max -> {sys.argv[2]}')
