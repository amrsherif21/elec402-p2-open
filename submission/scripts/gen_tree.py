#!/usr/bin/env python3
"""gen_tree.py -- generator for a drop-in mult_pipe.sv (ports clk, RST_N, en, a, b, p):
pipelined signed 16x16 multiplier with radix-4 Booth partial products, a BIT-LEVEL
column-compression tree (Dadda 1965 / Wallace 1964 / timing-driven fill) and a
pipelined final adder.  Written for this project.

Datapath (every stage ends in a register rank):
  R1  operand register: a (16) and the Booth digits one/two/neg of b (24); b is recoded
      before the register; the register loads zeros when en = 0 (operand isolation)
  S2  Booth selection  pp_i = ((one_i & a) | (two_i & 2a)) ^ neg_i  (8 rows x 17 bits)
  R2  selected partial products (136) + the 8 neg bits (the "+1" of negative rows)
  ... tree stages: column compression with full / half adders; the cut positions are
      either "after level k" (level-based Dadda / Wallace) or arrival-budget driven
  ... adder stages: carry-increment (default) or carry-select, then the product register
Sign extension: classic form, row 0 top bits {~s0, s0, s0}, rows i >= 1 {1, ~s_i}; the
constant ones are tree inputs that are never registered.  Every register has a
synchronous active-low reset.

usage: gen_tree.py OUT.sv [options]   (prints a stage / cutset summary; --stats only
       prints the level statistics of Dadda and Wallace)
  run.sh RUN NAME [options] generates NAME/rtl, unit-tests it (tb_mult.sv, 200k random +
  corner operands) and runs submission/scripts/eval_candidate.sh.
Best configurations found (see the per-candidate eval.txt):
  800 MHz, 6 ranks, 431 flops, WNS +0.096 (w24r3gt5re):
    --mode wallace --rawlevels 3 --cuts 2,4 --gp gt --k0 8 --k 5 --res-budget 0.66 --extra 0.72
  400 MHz, 3 ranks, 141 flops, WNS +0.151 (w4r3cpa):
    --mode wallace --rawlevels 3 --nosel --cuts 4 --gp cpa --cpa one --res-budget 1.9
Delay model (model ns): XOR --dx, AND/OR --da; the level-based modes ignore it except for
the input assignment (latest input on the fast input) and the optional extras.
"""
import argparse, sys

ap = argparse.ArgumentParser()
ap.add_argument("out", nargs="?")
ap.add_argument("--mode", default="dadda", choices=["dadda", "wallace", "fill"])
ap.add_argument("--wlevels", type=int, default=99, help="wallace: levels done Wallace-style; the rest Dadda")
ap.add_argument("--cuts", default="2,4", help="level-based: register after these levels (last = 2 rows)")
ap.add_argument("--budgets", default="0.72,0.72", help="fill: logic budget (model ns) of each tree stage")
ap.add_argument("--target", default="", help="fill: per-stage target column height (default 2 = greedy)")
ap.add_argument("--res", action="store_true", help="resolve low columns to 1 bit (ripple) inside tree stages")
ap.add_argument("--gp", default="tree", choices=["tree", "gt", "cpa"], help="where p = x^y, g = x&y is formed")
ap.add_argument("--cpa", default="cinc", choices=["cinc", "csel", "one"],
                help="cinc: carry-increment, 2 stages; csel: carry-select (s0/s1), 2 stages; one: 1-stage KS")
ap.add_argument("--k", type=int, default=8, help="adder block size")
ap.add_argument("--k0", type=int, default=0, help="size of the first adder block (default k)")
ap.add_argument("--dx", type=float, default=0.18)
ap.add_argument("--da", type=float, default=0.12)
ap.add_argument("--bpair", action="store_true", help="first block-prefix level in adder stage A")
ap.add_argument("--res-budget", type=float, default=0.0, help="level mode: ripple-resolve low columns in the last tree stage up to this arrival")
ap.add_argument("--bsel", action="store_true", help="adder stage B: select the incremented block sum by the block carry")
ap.add_argument("--rawlevels", type=int, default=0, help="wallace: in the first N levels no half adder in columns of height <= 2")
ap.add_argument("--res-mid", type=float, default=0.0, help="level mode: ripple-resolve low columns before each mid-tree cut up to this arrival")
ap.add_argument("--nosel", action="store_true", help="no register after the Booth selection (400 MHz)")
ap.add_argument("--sel-t", type=float, default=0.55, help="model arrival of the selected bits with --nosel")
ap.add_argument("--extra", type=float, default=0.0, help="level mode: extra full adders on early bits before mid-tree cuts, up to this arrival")
ap.add_argument("--extra-h", type=int, default=4, help="column height limit for --extra")
ap.add_argument("--stats", action="store_true")
ap.add_argument("--tag", default="")
args = ap.parse_args()

W = 32
ONE, ZERO = "1'b1", "1'b0"
DX, DA = args.dx, args.da
EPS = 1e-9
CONST_T = -1.0

def is_const(e):
    return e in (ONE, ZERO)

def inv(e):
    if e == ONE: return ZERO
    if e == ZERO: return ONE
    return e[1:] if e.startswith("~") else "~" + e

def base(e):
    return e[1:] if e.startswith("~") else e

# ---------------------------------------------------------------------------
class Net:
    """collects wire declarations per stage; gates with constant folding"""
    def __init__(self):
        self.lines = []
        self.n = 0
        self.fa = 0
        self.ha = 0
    def wire(self, pfx, expr):
        self.n += 1
        nm = f"{pfx}{self.n}"
        self.lines.append(f"    wire {nm} = {expr};")
        return nm
    def xor(self, a, b):
        if a == ZERO: return b
        if b == ZERO: return a
        if a == ONE: return inv(b)
        if b == ONE: return inv(a)
        return self.wire("x", f"{a} ^ {b}")
    def and_(self, a, b):
        if ZERO in (a, b): return ZERO
        if a == ONE: return b
        if b == ONE: return a
        return self.wire("n", f"{a} & {b}")
    def or_(self, a, b):
        if ONE in (a, b): return ONE
        if a == ZERO: return b
        if b == ZERO: return a
        return self.wire("o", f"{a} | {b}")

net = Net()

# bits are (expr, arrival); constants have arrival CONST_T
def fa(x, y, z):
    """full adder; z should be the latest input. returns (sum, carry)"""
    net.fa += 1
    bs = sorted([x, y, z], key=lambda b: b[1])
    consts = [b for b in bs if is_const(b[0])]
    v = [b for b in bs if not is_const(b[0])]
    if len(consts) == 1 and consts[0][0] == ONE:            # x + y + 1
        a, b = v
        t = max(a[1], b[1])
        s = (inv(net.xor(a[0], b[0])), t + DX)
        c = (net.or_(a[0], b[0]), t + DA)
        return s, c
    if len(consts) >= 2:
        raise RuntimeError("two constants in a full adder")
    x, y, z = bs
    t = net.xor(x[0], y[0]); tt = max(x[1], y[1]) + DX
    s = net.xor(t, z[0]);   ts = max(tt, z[1]) + DX
    g = net.and_(x[0], y[0])
    c = net.or_(g, net.and_(z[0], t))
    tc = max(tt, z[1]) + DA
    return (s, ts), (c, tc)

def ha(x, y):
    net.ha += 1
    if y[0] == ONE: x, y = y, x
    if x[0] == ONE:                                          # y + 1
        return (inv(y[0]), y[1]), (y[0], y[1])
    t = max(x[1], y[1])
    return (net.xor(x[0], y[0]), t + DX), (net.and_(x[0], y[0]), t + DA)

# ---------------------------------------------------------------------------
# registers
regs = []   # (name, [(dst, src)])
def register(name, exprs):
    """register the distinct non-constant base signals of exprs; returns map expr -> new"""
    order, idx = [], {}
    for e in exprs:
        if is_const(e): continue
        b = base(e)
        if b not in idx:
            idx[b] = len(order); order.append(b)
    regs.append((name, [(f"{name}[{i}]", b) for i, b in enumerate(order)]))
    m = {}
    for e in exprs:
        if is_const(e): m[e] = e
        else:
            r = f"{name}[{idx[base(e)]}]"
            m[e] = inv(r) if e.startswith("~") else r
    return m, len(order)

def reg_cols(name, cols):
    m, n = register(name, [b[0] for c in cols for b in c])
    return [[(m[b[0]], 0.0 if not is_const(b[0]) else CONST_T) for b in c] for c in cols], n

def nvar(cols):
    return len({base(b[0]) for c in cols for b in c if not is_const(b[0])})

# ---------------------------------------------------------------------------
# Booth matrix (after R2): ppr[i][j] = selected bit j of row i, ngr[i] = neg_i
def booth_matrix(pp, ng):
    cols = [[] for _ in range(W)]
    for i in range(8):
        for j in range(16):
            cols[2 * i + j].append(pp[i][j])
        cols[2 * i].append(ng[i])
        s = pp[i][16]
        if i == 0:   # {~s0, s0, s0} at columns 18, 17, 16
            cols[16].append(s); cols[17].append(s); cols[18].append((inv(s[0]), s[1]))
        else:        # {1, ~s_i} at columns 2i+17, 2i+16
            cols[2 * i + 16].append((inv(s[0]), s[1]))
            if 2 * i + 17 < W:
                cols[2 * i + 17].append((ONE, CONST_T))
    return cols

# ---------------------------------------------------------------------------
# level-based reductions (no timing; inputs taken earliest-first)
DADDA = [2, 3, 4, 6, 9, 13, 19]
WALLACE_HA_MIN = 2   # a leftover pair goes to a half adder in columns at least this high

def level_dadda(cols, d):
    out = [[] for _ in range(W)]
    carries = [[] for _ in range(W + 1)]
    nf = nh = 0
    for c in range(W):
        bits = sorted(cols[c], key=lambda b: b[1])
        h = len(bits) + len(carries[c])
        while h > d:
            if h - d >= 2 and len(bits) >= 3:
                s, cy = fa(bits[0], bits[1], bits[2]); bits = bits[3:]; h -= 2; nf += 1
            else:
                s, cy = ha(bits[0], bits[1]); bits = bits[2:]; h -= 1; nh += 1
            out[c].append(s)
            if c + 1 < W: carries[c + 1].append(cy)
        out[c] += bits + carries[c]
    return out, nf, nh

def level_wallace(cols, ha_min=WALLACE_HA_MIN):
    out = [[] for _ in range(W)]
    carries = [[] for _ in range(W + 1)]
    nf = nh = 0
    for c in range(W):
        bits = sorted(cols[c], key=lambda b: b[1])
        while len(bits) >= 3:
            s, cy = fa(bits[0], bits[1], bits[2]); bits = bits[3:]; nf += 1
            out[c].append(s)
            if c + 1 < W: carries[c + 1].append(cy)
        if len(bits) == 2 and len(cols[c]) >= ha_min:
            s, cy = ha(bits[0], bits[1]); bits = []; nh += 1
            out[c].append(s)
            if c + 1 < W: carries[c + 1].append(cy)
        out[c] += bits
    for c in range(W):
        out[c] += carries[c]
    return out, nf, nh

def maxh(cols):
    return max(len(c) for c in cols)

def arr(cols):
    return max([b[1] for c in cols for b in c] + [0.0])

# ---------------------------------------------------------------------------
# timing-driven fill of one stage: three-greedy (earliest three bits, latest on the
# fast input), column by column, as long as the outputs stay within the budget.
def fill_stage(cols, budget, target=2, res_lo=None):
    """res_lo: first unresolved column (all below hold one final bit) or None"""
    cols = [list(c) for c in cols]
    nf = nh = 0
    lo = res_lo
    for c in range(W):
        while len(cols[c]) > target:
            bs = sorted(cols[c], key=lambda b: (b[1], not is_const(b[0])))
            x, y, z = bs[0], bs[1], bs[2]
            nc = sum(is_const(b[0]) for b in (x, y, z))
            if nc >= 2:
                # 1 + 1 = carry 1 into the next column
                k = [b for b in bs if is_const(b[0])][:2]
                for b in k: cols[c].remove(b)
                if c + 1 < W: cols[c + 1].append((ONE, CONST_T))
                continue
            t = max(b[1] for b in (x, y, z) if not is_const(b[0]))
            if nc == 1:
                ok = t + DX <= budget + EPS
            else:
                tt = max(x[1], y[1]) + DX
                ok = max(tt, z[1]) + DX <= budget + EPS
            if not ok:
                break
            for b in (x, y, z): cols[c].remove(b)
            s, cy = fa(x, y, z); nf += 1
            cols[c].append(s)
            if c + 1 < W: cols[c + 1].append(cy)
        if lo is not None and lo == c and len(cols[c]) <= 2:
            if len(cols[c]) == 2:
                x, y = sorted(cols[c], key=lambda b: b[1])
                if max(x[1], y[1]) + DX <= budget + EPS:
                    cols[c] = []
                    s, cy = ha(x, y); nh += 1
                    cols[c].append(s)
                    if c + 1 < W: cols[c + 1].append(cy)
            if len(cols[c]) <= 1:
                lo = c + 1
    return cols, nf, nh, lo

def fill_final(cols):
    """last tree stage: every column to <= 2 bits (Dadda rule: half adder when one bit
    over, else full adder), earliest bits into the adders, the latest bit passes"""
    cols = [list(c) for c in cols]
    nf = nh = 0
    for c in range(W):
        while len(cols[c]) > 2:
            bs = sorted(cols[c], key=lambda b: (b[1], not is_const(b[0])))
            if sum(is_const(b[0]) for b in bs[:2]) == 2:
                cols[c].remove(bs[0]); cols[c].remove(bs[1])
                if c + 1 < W: cols[c + 1].append((ONE, CONST_T))
                continue
            if len(bs) == 3:
                x, y = bs[0], bs[1]
                cols[c].remove(x); cols[c].remove(y)
                s_, cy = ha(x, y); nh += 1
            else:
                x, y, z = bs[0], bs[1], bs[2]
                if is_const(z[0]) and is_const(y[0]):
                    x, y, z = bs[0], bs[1], bs[3]
                for b_ in (x, y, z): cols[c].remove(b_)
                s_, cy = fa(x, y, z); nf += 1
            cols[c].append(s_)
            if c + 1 < W: cols[c + 1].append(cy)
    return cols, nf, nh

def ripple_low(cols, budget):
    """resolve the lowest columns (<= 2 bits each) to one bit with half / full adders
    while the outputs stay within the budget (a ripple-carry adder on the LSBs).
    A step is kept only if it leaves no column with three bits."""
    global net
    cols = [list(c) for c in cols]
    n = 0
    c = 0
    while c < W and len(cols[c]) <= 1:
        c += 1
    while c < W:
        # tentative: resolve column c, then any column the carry pushes to 3 bits
        save_lines, save_n, save_fa, save_ha = len(net.lines), net.n, net.fa, net.ha
        tc = [list(x) for x in cols]
        k, ok, m = c, True, 0
        while k < W:
            bs = sorted(tc[k], key=lambda b: b[1])
            if len(bs) <= 2 and k > c:
                break
            if len(bs) == 2:
                s_, cy = ha(bs[0], bs[1])
            elif len(bs) == 3:
                s_, cy = fa(bs[0], bs[1], bs[2])
            else:
                break
            m += 1
            if max(s_[1], cy[1]) > budget + EPS:
                ok = False; break
            tc[k] = [s_]
            if k + 1 < W: tc[k + 1].append(cy)
            k += 1
        if not ok or m == 0 or (k < W and len(tc[k]) > 2 and not (k == c)):
            del net.lines[save_lines:]
            net.n, net.fa, net.ha = save_n, save_fa, save_ha
            break
        cols, n = tc, n + m
        c = k
        while c < W and len(cols[c]) <= 1:
            c += 1
    return cols, n, c

def extra_fa(cols, budget, hmax):
    """full adders on the three earliest bits of a column where the sum and carry fit
    the budget and no column grows above hmax (keeps the remaining level count)"""
    cols = [list(c) for c in cols]
    n = 0
    for c in range(W):
        while len(cols[c]) >= 3:
            bs = sorted(cols[c], key=lambda b: b[1])
            x, y, z = bs[0], bs[1], bs[2]
            if any(is_const(b_[0]) for b_ in (x, y, z)): break
            tt = max(x[1], y[1]) + DX
            if max(tt, z[1]) + DX > budget + EPS: break
            if c + 1 < W and len(cols[c + 1]) + 1 > hmax: break
            for b_ in (x, y, z): cols[c].remove(b_)
            s_, cy = fa(x, y, z); n += 1
            cols[c].append(s_)
            if c + 1 < W: cols[c + 1].append(cy)
    return cols, n

# ---------------------------------------------------------------------------
def emit_stage_comment(txt):
    net.lines.append(f"    // ---- {txt}")

summary = []
# ---- R1 / S2 / R2
emit_stage_comment("stage 2: Booth selection pp_i = ((one_i & a) | (two_i & 2a)) ^ neg_i")
net.lines.append("    wire [16:0] a17 = {a_q[15], a_q};")
net.lines.append("    wire [16:0] a2  = {a_q, 1'b0};")
pps = []
for i in range(8):
    net.lines.append(f"    wire [16:0] pp{i} = (({{17{{one_q[{i}]}}}} & a17) | ({{17{{two_q[{i}]}}}} & a2)) ^ {{17{{neg_q[{i}]}}}};")
    pps += [f"pp{i}[{j}]" for j in range(17)]
pps += [f"neg_q[{i}]" for i in range(8)]
summary.append(f"R1 operands + Booth digits: 40 flops")
if args.nosel:
    # no register after the selection: the tree continues in the same stage
    ppr = [[(f"pp{i}[{j}]", args.sel_t) for j in range(17)] for i in range(8)]
    ngr = [(f"neg_q[{i}]", 0.0) for i in range(8)]
    n2 = None
else:
    m2, n2 = register("r2", pps)
    ppr = [[(m2[f"pp{i}[{j}]"], 0.0) for j in range(17)] for i in range(8)]
    ngr = [(m2[f"neg_q[{i}]"], 0.0) for i in range(8)]
    summary.append(f"R2 selected partial products + neg bits: {n2} flops")
cols0 = booth_matrix([[b for b in row] for row in ppr], ngr)
heights0 = [len(c) for c in cols0]
ranks = [40] + ([n2] if n2 is not None else [])

# ---- statistics of the level-based trees (separate gate counters)
def level_stats(kind):
    global net
    save = net
    net = Net()
    cols = cols0; out = []
    lv = 0
    while maxh(cols) > 2:
        lv += 1
        if kind == "dadda":
            d = max(x for x in DADDA if x < maxh(cols))
            cols, nf, nh = level_dadda(cols, d)
        else:
            cols, nf, nh = level_wallace(cols)
        out.append((lv, nf, nh, maxh(cols), nvar(cols), [len(c) for c in cols]))
    net = save
    return out

if args.stats:
    print("column heights:", heights0, "max", max(heights0), "variable bits", nvar(cols0))
    for kind in ("dadda", "wallace"):
        st = level_stats(kind)
        print(f"{kind}: FA {sum(s[1] for s in st)} HA {sum(s[2] for s in st)}")
        for s in st:
            print(f"  level {s[0]}: FA {s[1]:3d} HA {s[2]:2d} max height {s[3]} cutset {s[4]:3d}  heights {s[5]}")
    sys.exit(0)

# ---- tree stages
cols = cols0
stage = 2 if args.nosel else 3
lo = 0 if args.res else None
tree_desc = []
gp = None
if args.mode in ("dadda", "wallace"):
    cuts = [int(x) for x in args.cuts.split(",")]
    lv = 0
    emit_stage_comment(f"stage {stage}: {args.mode} levels")
    sf = sh = 0
    while maxh(cols) > 2:
        lv += 1
        f0, h0 = net.fa, net.ha
        if args.mode == "dadda" or lv > args.wlevels:
            d = max(x for x in DADDA if x < maxh(cols))
            cols, nf, nh = level_dadda(cols, d)
        else:
            cols, nf, nh = level_wallace(cols, 3 if lv <= args.rawlevels else 2)
        sf += nf; sh += nh
        net.lines.append(f"    // level {lv}: {nf} FA, {nh} HA, max height {maxh(cols)}")
        last = maxh(cols) <= 2
        if not last and lv in cuts and args.extra > 0:
            cols, ne = extra_fa(cols, args.extra, args.extra_h)
            net.lines.append(f"    // extra full adders on early bits before the cut: {ne}")
            summary.append(f"S{stage}: {ne} extra full adders on early bits")
            sf += ne
        rb = args.res_budget if last else (args.res_mid if lv in cuts else 0)
        if rb > 0:
            cols, nr, rlo = ripple_low(cols, rb)
            net.lines.append(f"    // ripple: columns below {rlo} resolved to one bit ({nr} adders)")
            summary.append(f"S{stage}: low columns resolved below {rlo} by ripple ({nr} adders)")
        if lv in cuts or last:
            if last and args.gp in ("tree", "gt"):
                break
            t = arr(cols)
            cols, n = reg_cols(f"r{stage}", cols)
            summary.append(f"R{stage} after level {lv}: {sf} FA {sh} HA, model arrival {t:.2f}, {n} flops")
            ranks.append(n)
            stage += 1; sf = sh = 0
            emit_stage_comment(f"stage {stage}: {args.mode} levels")
    tree_last_arr = arr(cols)
    tree_desc = f"{args.mode} cuts after levels {args.cuts}"
else:
    budgets = [float(x) for x in args.budgets.split(",")]
    targets = [int(x) for x in args.target.split(",")] if args.target else []
    k = 0
    while True:
        b = budgets[min(k, len(budgets) - 1)]
        tg = targets[k] if k < len(targets) else 2
        emit_stage_comment(f"stage {stage}: timing-driven compression, budget {b}, target {tg}")
        f0, h0 = net.fa, net.ha
        if tg == 0:
            cols, nf, nh = fill_final(cols)
        else:
            cols, nf, nh, lo = fill_stage(cols, b, tg, lo)
        done = maxh(cols) <= 2
        if done and args.gp in ("tree", "gt"):
            # p/g must also fit
            if arr(cols) + DX <= b + EPS:
                tree_last_arr = arr(cols)
                summary.append(f"S{stage}: {nf} FA {nh} HA (+ p/g)")
                break
        t = arr(cols)
        cols, n = reg_cols(f"r{stage}", cols)
        summary.append(f"R{stage} after fill stage: {nf} FA {nh} HA, max height {maxh(cols)}, model arrival {t:.2f}, {n} flops" + (f", low columns resolved below {lo}" if lo else ""))
        ranks.append(n)
        stage += 1; k += 1
        if done:
            tree_last_arr = 0.0
            break
        if k > 10: sys.exit("no progress")
    tree_desc = f"fill budgets {args.budgets} targets {args.target or '2'}" + (" res" if args.res else "")

# ---- p / g per column
emit_stage_comment(f"stage {stage}: propagate / generate per column")
pg = []
tp = {}
gp_in_tree = not all(r == 0.0 or r == CONST_T for c in cols for (e, r) in c)
if gp_in_tree and args.gp == "gt":
    # tree end + generate g = x & y and transmit t = x | y (one fast gate level);
    # the adder stage recovers p = t & ~g
    ex = []
    for c in range(W):
        bs = [b_[0] for b_ in cols[c]]
        if len(bs) == 0: pg.append((ZERO, ZERO, ZERO))
        elif len(bs) == 1: pg.append((bs[0], ZERO, bs[0]))
        else:
            x, y = bs
            pg.append((None, net.and_(x, y) if c + 1 < W else ZERO, net.or_(x, y) if c + 1 < W else net.xor(x, y)))
        ex += [pg[-1][1], pg[-1][2]]
    mg, ng_ = register(f"r{stage}", ex)
    summary.append(f"R{stage} tree end, generate / transmit per column (model arrival {tree_last_arr + DA:.2f}): {ng_} flops")
    ranks.append(ng_)
    stage += 1
    emit_stage_comment(f"stage {stage}: final adder; p = t & ~g")
    pg2 = []
    for c, (p0, g0, t0) in enumerate(pg):
        g, t = mg[g0], mg[t0]
        if p0 is None and c + 1 < W:
            p = net.and_(t, inv(g)); tp[c] = t
        else:
            p = t      # single bit (g = 0), or column 31 (t holds x ^ y)
        pg2.append((p, g))
    pg = pg2
else:
    emit_stage_comment(f"stage {stage}: propagate / generate per column")
    for c in range(W):
        bs = [b_[0] for b_ in cols[c]]
        if len(bs) == 0: pg.append((ZERO, ZERO))
        elif len(bs) == 1: pg.append((bs[0], ZERO))
        else:
            x, y = bs
            pg.append((net.xor(x, y), net.and_(x, y) if c + 1 < W else ZERO))
            if not gp_in_tree and c + 1 < W:
                tp[c] = net.or_(x, y)   # transmit (x | y): propagate for the carry prefix
    if gp_in_tree:
        # the tree's last level and p/g share a stage: register p/g
        ex = [x for p_, g_ in pg for x in (p_, g_)]
        mg, ng_ = register(f"r{stage}", ex)
        summary.append(f"R{stage} tree end, p/g per column (model arrival {tree_last_arr + DX:.2f}): {ng_} flops")
        ranks.append(ng_)
        pg = [(mg[p_], mg[g_]) for p_, g_ in pg]
        stage += 1
        emit_stage_comment(f"stage {stage}: final adder")

def ks(G, P, d=1):
    """Kogge-Stone inclusive prefix: G[i] = generate of positions i..0 (from span d)"""
    G, P = list(G), list(P)
    while d < len(G):
        G2, P2 = list(G), list(P)
        for i in range(d, len(G)):
            G2[i] = net.or_(G[i], net.and_(P[i], G[i - d]))
            P2[i] = net.and_(P[i], P[i - d])
        G, P = G2, P2
        d *= 2
    return G, P

tpr = [tp.get(c, pg[c][0]) for c in range(W)]   # registered p/g: p itself
lo_c = 0
while lo_c < W and pg[lo_c][1] == ZERO:
    lo_c += 1
# columns 0..lo_c take no carry: their sum is p
blocks = []
c = lo_c
k0 = args.k0 or args.k
while c < W:
    sz = k0 if not blocks else args.k
    blocks.append((c, min(c + sz, W)))
    c += sz
nb = len(blocks)
fin = [pg[c][0] for c in range(lo_c)]

if args.cpa == "one":
    G, P = ks([g for p, g in pg], tpr)
    prod = [pg[0][0]] + [net.xor(pg[c][0], G[c - 1]) for c in range(1, W)]
    cpa_desc = "single-stage Kogge-Stone"
else:
    items = list(fin)
    s0 = {}; s1 = {}; BG = {}; BP = {}
    for bi, (l, h) in enumerate(blocks):
        gs = [pg[c][1] for c in range(l, h)]; ps = [pg[c][0] for c in range(l, h)]
        Gp, Pp = ks(gs, [tpr[c] for c in range(l, h)])
        for kk, c in enumerate(range(l, h)):
            s0[c] = ps[kk] if kk == 0 else net.xor(ps[kk], Gp[kk - 1])
            if args.cpa == "csel" and bi > 0:
                s1[c] = inv(ps[kk]) if kk == 0 else net.xor(ps[kk], net.or_(Gp[kk - 1], Pp[kk - 1]))
        BG[bi] = Gp[-1]
        BP[bi] = net.or_(Gp[-1], Pp[-1]) if args.cpa == "csel" else Pp[-1]
    if args.bpair:
        # first Kogge-Stone level over the blocks in stage A: G[b:b-1], P[b:b-1]
        G1 = {0: BG[0]}; P1 = {}
        for bi in range(1, nb - 1):
            G1[bi] = net.or_(BG[bi], net.and_(BP[bi], BG[bi - 1]))
            if bi >= 2: P1[bi] = net.and_(BP[bi], BP[bi - 1])
        BG, BP = G1, P1
    for bi, (l, h) in enumerate(blocks):
        items += [s0[c] for c in range(l, h)]
        if args.cpa == "csel" and bi > 0: items += [s1[c] for c in range(l, h)]
        if bi < nb - 1: items.append(BG[bi])
        if bi in BP and 0 < bi < nb - 1 and (not args.bpair or bi >= 2): items.append(BP[bi])
    t_regA = stage
    mA, nA = register(f"r{stage}", items)
    ranks.append(nA)
    summary.append(f"R{stage} adder stage A ({args.cpa}, blocks {blocks}): {nA} flops")
    stage += 1
    emit_stage_comment(f"stage {stage}: block carries (prefix over blocks) and selection")
    rG = [mA[BG[bi]] for bi in range(nb - 1)]
    rP = [mA[BP[bi]] if bi in BP and bi >= (2 if args.bpair else 1) else ZERO for bi in range(nb - 1)]
    # (carry-select: carry out of block = co0 | (co1 & cin), prefix with g = co0, p = co1)
    Gc, _ = ks(rG, rP, 2 if args.bpair else 1)
    cin = [ZERO] + Gc
    prod = [mA[e] for e in fin]
    for bi, (l, h) in enumerate(blocks):
        if bi == 0:
            prod += [mA[s0[c]] for c in range(l, h)]
            continue
        if args.cpa == "csel":
            for c in range(l, h):
                a0, a1 = mA[s0[c]], mA[s1[c]]
                prod.append(net.or_(net.and_(inv(cin[bi]), a0), net.and_(cin[bi], a1)))
        else:
            # increment: s = s0 + cin, all-ones prefix of s0 inside the block
            sv = [mA[s0[c]] for c in range(l, h)]
            # Kogge-Stone AND prefix
            A = list(sv); d = 1
            while d < len(A):
                A = [A[i] if i < d else net.and_(A[i], A[i - d]) for i in range(len(A))]
                d *= 2
            for kk in range(len(sv)):
                if args.bsel:
                    # incremented sum formed beside the block carry, then selected by it
                    inc = inv(sv[0]) if kk == 0 else net.xor(sv[kk], A[kk - 1])
                    prod.append(net.or_(net.and_(cin[bi], inc), net.and_(inv(cin[bi]), sv[kk])))
                elif kk == 0: prod.append(net.xor(sv[0], cin[bi]))
                else: prod.append(net.xor(sv[kk], net.and_(cin[bi], A[kk - 1])))
    cpa_desc = {"cinc": "two-stage carry-increment", "csel": "two-stage carry-select"}[args.cpa] + f", blocks {blocks}"
assert len(prod) == W, len(prod)
net.lines.append("    assign prod = {" + ", ".join(reversed(prod)) + "};")
ranks.append(32)
LAT = len(ranks)
summary.append(f"R{stage} product: 32 flops")

# ---------------------------------------------------------------------------
if args.out:
    o = []
    o.append("// mult_pipe.sv -- GENERATED by submission/scripts/gen_tree.py; edit the generator, not this file.")
    o.append(f"// generator arguments: {' '.join(sys.argv[2:])}")
    o.append("//")
    o.append("// Pipelined signed 16x16 multiplier: radix-4 Booth partial products (8 rows of 17")
    o.append("// bits, classic sign extension {~s0,s0,s0} / {1,~si}, the +1 of each negative row as")
    o.append(f"// a separate bit), bit-level column compression ({tree_desc}),")
    o.append(f"// final adder: {cpa_desc}.")
    o.append(f"// Register ranks (latency from 'en' to 'p'): {LAT}; datapath flops {sum(ranks)}:")
    for s in summary:
        o.append("//   " + s)
    o.append(f"// Full adders {net.fa}, half adders {net.ha}. Constant bits are never registered.")
    o.append("// Every register has a synchronous active-low reset (SPEC F14); the operand register")
    o.append("// loads zeros when en = 0 (operand isolation).")
    o.append("module mult_pipe (")
    o.append("    input  logic               clk,")
    o.append("    input  logic               RST_N,")
    o.append("    input  logic               en,     // accept: load operands, else load zeros")
    o.append("    input  logic signed [15:0] a,      // multiplicand (unregistered input)")
    o.append("    input  logic signed [15:0] b,      // multiplier   (unregistered input)")
    o.append("    output logic signed [31:0] p       // product, registered")
    o.append(");")
    o.append("    // Booth radix-4 recoding of y: digit_i = -2 y[2i+1] + y[2i] + y[2i-1]")
    o.append("    function automatic logic [23:0] booth_enc(input logic [15:0] y);")
    o.append("        logic [16:0] yx;")
    o.append("        logic [7:0]  one, two, neg;")
    o.append("        yx = {y, 1'b0};")
    o.append("        for (int i = 0; i < 8; i++) begin")
    o.append("            one[i] = yx[2*i+1] ^ yx[2*i];")
    o.append("            two[i] = (yx[2*i+2] & ~yx[2*i+1] & ~yx[2*i]) | (~yx[2*i+2] & yx[2*i+1] & yx[2*i]);")
    o.append("            neg[i] = yx[2*i+2];")
    o.append("        end")
    o.append("        booth_enc = {neg, two, one};")
    o.append("    endfunction")
    o.append("")
    o.append("    // ---- stage 1: operand register (operand isolation: zeros when idle)")
    o.append("    logic [15:0] a_q;")
    o.append("    logic [7:0]  one_q, two_q, neg_q;")
    o.append("    always_ff @(posedge clk) begin")
    o.append("        if (!RST_N || !en) begin")
    o.append("            a_q <= '0; one_q <= '0; two_q <= '0; neg_q <= '0;")
    o.append("        end else begin")
    o.append("            a_q <= a; {neg_q, two_q, one_q} <= booth_enc(b);")
    o.append("        end")
    o.append("    end")
    o.append("")
    for name, pairs in regs:
        o.append(f"    logic [{len(pairs) - 1}:0] {name};")
    o.append("    logic [31:0] prod;")
    o.append("")
    o.extend(net.lines)
    o.append("")
    for name, pairs in regs:
        o.append(f"    // register {name}: {len(pairs)} flops")
        o.append("    always_ff @(posedge clk) begin")
        o.append(f"        if (!RST_N) {name} <= '0;")
        o.append("        else begin")
        for d, s in pairs:
            o.append(f"            {d} <= {s};")
        o.append("        end")
        o.append("    end")
    o.append("    // product register")
    o.append("    always_ff @(posedge clk) begin")
    o.append("        if (!RST_N) p <= '0;")
    o.append("        else        p <= prod;")
    o.append("    end")
    o.append("endmodule : mult_pipe")
    open(args.out, "w").write("\n".join(o) + "\n")
print(f"LAT={LAT} ranks={ranks} datapath flops={sum(ranks)} FA={net.fa} HA={net.ha}")
for s in summary:
    print("  " + s)
