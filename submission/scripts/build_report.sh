#!/usr/bin/env bash
# build_report.sh -- builds submission/pdf_report/report.pdf from
# submission/pdf_report/src/report.md with pandoc + pdflatex. It fills in the
# placeholders: SIGNOFF_SECTION (src/signoff.md), TOKEN_TABLE (token_usage.py),
# WALLCLOCK_END (current UTC time) and LISTING (all sources of the submission).
set -euo pipefail
cd "$(dirname "$0")/../.."
S=submission/pdf_report/src
B=build/report; mkdir -p $B
python3 submission/scripts/token_usage.py > $B/tokens.md
{
  for f in Makefile submission/rtl_400/*.sv submission/rtl_800/*.sv submission/testbench/*.sv \
           submission/testbench/timing_fail/rtl_onestage/mkMultBuff.sv \
           submission/scripts/*.sh submission/scripts/*.tcl submission/scripts/*.py \
           submission/scripts/*.script submission/scripts/waves/*; do
    echo; echo "## \`$f\` {.unnumbered .unlisted}"; echo; echo '```'; cat "$f"; echo '```'
  done
} > $B/listing.md
python3 - "$S/report.md" "$S/signoff.md" "$B/tokens.md" "$B/listing.md" "$B/report.md" <<'PY'
import sys, time
rep, so, tok, lst, out = sys.argv[1:]
s = open(rep).read()
s = s.replace('SIGNOFF_SECTION', open(so).read().strip())
s = s.replace('TOKEN_TABLE', open(tok).read().strip())
s = s.replace('WALLCLOCK_END', time.strftime('%H:%M', time.gmtime()))
s = s.replace('LISTING', open(lst).read())
open(out, 'w').write(s)
PY
cat > $B/header.tex <<'EOF'
\usepackage{float}
\floatplacement{figure}{H}
\DeclareUnicodeCharacter{00B5}{\ensuremath{\mu}}
\DeclareUnicodeCharacter{00D7}{\ensuremath{\times}}
\DeclareUnicodeCharacter{2192}{\ensuremath{\rightarrow}}
\DeclareUnicodeCharacter{2212}{\ensuremath{-}}
\DeclareUnicodeCharacter{2265}{\ensuremath{\geq}}
\DeclareUnicodeCharacter{2264}{\ensuremath{\leq}}
\DeclareUnicodeCharacter{2248}{\ensuremath{\approx}}
\DeclareUnicodeCharacter{2026}{\ldots}
\DeclareUnicodeCharacter{00B1}{\ensuremath{\pm}}
\DeclareUnicodeCharacter{00B0}{\ensuremath{^\circ}}
\usepackage{multicol}
\setlength{\columnsep}{12pt}
\newcommand{\startcols}{\begin{multicols}{2}}
\newcommand{\stopcols}{\end{multicols}}
% source appendix: small monospace, no frame, tight line spacing
\lstset{basicstyle=\ttfamily\fontsize{5.5}{6.2}\selectfont, breaklines=true,
        columns=fullflexible, keepspaces=true, frame=none, showstringspaces=false,
        aboveskip=2pt, belowskip=2pt}
EOF
cd $S
pandoc ../../../$B/report.md -o ../report.pdf --pdf-engine=pdflatex --listings \
  --number-sections --toc --toc-depth=2 -V geometry:margin=2.2cm -V fontsize=10pt \
  -V colorlinks=true -V linkcolor=blue -V urlcolor=blue --include-in-header=../../../$B/header.tex \
  --resource-path=.:..
echo "report written: submission/pdf_report/report.pdf ($(pdfinfo ../report.pdf 2>/dev/null | grep Pages || echo '?'))"
