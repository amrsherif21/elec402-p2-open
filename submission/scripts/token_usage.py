#!/usr/bin/env python3
"""token_usage.py [PROJECT_DIR] -- token usage and API-price cost of the agent session.

Reads every Claude Code transcript (*.jsonl) of this project under
~/.claude/projects/<project>/, i.e. the main session and every subagent, and sums
the usage of each API response once (deduplicated by message id + request id;
a streamed response is written as several transcript lines with the same usage).
Prices: Anthropic first-party API rates per million tokens (claude-api skill,
pricing table cached 2026-10-06): cache writes cost 1.25x input (5-minute TTL)
or 2x input (1-hour TTL); cache reads have model-specific prices.
Output: a Markdown table on stdout."""
import glob
import json
import os
import sys
from collections import defaultdict

# model: (input, output, cache read) in USD per million tokens
PRICES = {
    'claude-opus-5-5':   (4.00, 20.00, 0.20),
    'claude-sonnet-5-5': (2.00, 10.00, 0.20),
    'claude-haiku-5-5':  (0.10, 0.50, 0.01),
    'claude-fable-5-1':  (10.00, 50.00, 0.25),
    'claude-opus-5':     (5.00, 25.00, 0.50),
    'claude-sonnet-5':   (2.00, 10.00, 0.20),
}

proj = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    '~/.claude/projects/-home-user-elec402-p2-open')
files = sorted(glob.glob(os.path.join(proj, '**', '*.jsonl'), recursive=True))
seen = set()
tot = defaultdict(lambda: defaultdict(int))
per_file = defaultdict(lambda: defaultdict(int))
for f in files:
    who = 'main session'
    if '/subagents/' in f:
        try:
            who = 'subagent: ' + json.load(open(f[:-6] + '.meta.json'))['description']
        except (OSError, ValueError, KeyError):
            who = 'subagent ' + os.path.basename(f)[6:-6]
    for line in open(f, errors='replace'):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        m = d.get('message') if isinstance(d, dict) else None
        if not isinstance(m, dict) or 'usage' not in m or d.get('type') != 'assistant':
            continue
        key = (m.get('id'), d.get('requestId'))
        if key in seen:
            continue
        seen.add(key)
        u, model = m['usage'], m.get('model', 'unknown')
        cc = u.get('cache_creation') or {}
        w1h = cc.get('ephemeral_1h_input_tokens', 0)
        w5m = cc.get('ephemeral_5m_input_tokens', u.get('cache_creation_input_tokens', 0) - w1h)
        row = {'requests': 1, 'input': u.get('input_tokens', 0), 'output': u.get('output_tokens', 0),
               'cache_write_5m': w5m, 'cache_write_1h': w1h,
               'cache_read': u.get('cache_read_input_tokens', 0)}
        for k, v in row.items():
            tot[model][k] += v
            per_file[(who, model)][k] += v


def cost(model, r):
    pi, po, pr = PRICES.get(model, (float('nan'),) * 3)
    return (r['input'] * pi + r['output'] * po + r['cache_write_5m'] * 1.25 * pi
            + r['cache_write_1h'] * 2.0 * pi + r['cache_read'] * pr) / 1e6


cols = ['requests', 'input', 'output', 'cache_write_5m', 'cache_write_1h', 'cache_read']
heads = ['responses', 'input', 'output', 'cache write 5 min', 'cache write 1 h', 'cache read']
models = sorted(tot)
print(f"All responses were served by {', '.join(models)}. Token counts:\n")
print('| source | ' + ' | '.join(heads) + ' | cost (USD) |')
print('|' + '-' * 34 + '|' + '------:|' * (len(cols) + 1))
grand = 0.0
for (who, model), r in sorted(per_file.items()):
    label = who if len(models) == 1 else f'{who} ({model})'
    print(f'| {label} | ' + ' | '.join(f'{r[c]:,}' for c in cols) + f' | {cost(model, r):.2f} |')
for model, r in sorted(tot.items()):
    c = cost(model, r)
    grand += c
    label = 'total' if len(models) == 1 else f'total {model}'
    print(f'| **{label}** | ' + ' | '.join(f'**{r[c2]:,}**' for c2 in cols) + f' | **{c:.2f}** |')
print(f'\nTotal cost at API prices: **USD {grand:.2f}** '
      f'({len(files)} transcripts, {len(seen)} API responses).')
