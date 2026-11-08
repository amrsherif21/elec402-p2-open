#!/usr/bin/env bash
# install.sh -- reproducible open-source toolchain for mkMultBuff (SPEC.md Section 7).
# Run from the repository root:  bash submission/scripts/install.sh
# Installs simulator/viewer packages with apt, pulls pinned Docker images for
# synthesis (Yosys) and static timing / power (OpenSTA), and fetches the
# Nangate45 Open Cell Library (slow corner Liberty + Verilog cell models with
# specify blocks) from a public GitHub mirror at a pinned commit.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TECH="$ROOT/tech"

# Pinned versions (also recorded in submission/syn_reports/tool_versions.txt)
YOSYS_IMAGE="openroad/orfs@sha256:d3505fd5f930fcd20d3d25a41f3047230b7db7b7797e3448561c9e556cca3774"  # tag 26Q4-365-g898576f04, Yosys 0.68
STA_IMAGE="openroad/opensta@sha256:4162b4be70ee69eaa42e5eb3c830433393ff46cf0370f9b6c5b814b48a221a7a"  # tag f8e13cbf-ubuntu26.04, OpenSTA 3.1.0
PDK_REPO="https://raw.githubusercontent.com/mflowgen/freepdk-45nm"
PDK_SHA="d3be42a72ca6eabff54a4f3be50c16613f69f1b6"

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo "== apt packages (Icarus Verilog, GTKWave, Xvfb, LaTeX/pandoc for the report)"
if command -v apt-get >/dev/null; then
  $SUDO apt-get update -qq || true
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      iverilog gtkwave xvfb xauth make python3 curl git imagemagick \
      pandoc texlive-latex-base texlive-latex-recommended texlive-latex-extra \
      texlive-fonts-recommended librsvg2-bin >/dev/null || true
fi
for t in iverilog vvp python3 docker make curl; do
  command -v "$t" >/dev/null || { echo "missing required tool: $t"; exit 1; }
done

echo "== Docker daemon"
if ! docker info >/dev/null 2>&1; then
  ( $SUDO dockerd >/tmp/dockerd.log 2>&1 & ) ; sleep 8
  docker info >/dev/null 2>&1 || { echo "Docker daemon not available"; exit 1; }
fi
docker image inspect "$YOSYS_IMAGE" >/dev/null 2>&1 || docker pull "$YOSYS_IMAGE"
docker image inspect "$STA_IMAGE"   >/dev/null 2>&1 || docker pull "$STA_IMAGE"

echo "== Nangate45 Open Cell Library (FreePDK45), slow corner"
mkdir -p "$TECH"
fetch() { # url dest sha256
  if [ ! -f "$2" ] || ! echo "$3  $2" | sha256sum -c --quiet - 2>/dev/null; then
    curl -fsSL "$1" -o "$2"
  fi
  echo "$3  $2" | sha256sum -c --quiet - || { echo "checksum mismatch: $2"; exit 1; }
}
fetch "$PDK_REPO/$PDK_SHA/stdcells-wc.lib" "$TECH/NangateOpenCellLibrary_slow.lib" \
      182c2272055c846289211314ab014e669d9491b5c9fdb8dc2dce41d55d7fd8b7
fetch "$PDK_REPO/$PDK_SHA/stdcells.v"      "$TECH/NangateOpenCellLibrary.v" \
      05eefccd076e3ee557d61cf6187b162b3a05a5c6438b48a6c7cb59a270274679

echo "== tool versions"
mkdir -p "$ROOT/submission/syn_reports"
{
  echo "# Tool versions recorded by install.sh on $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "host: $(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)"
  echo "iverilog: $(iverilog -V 2>&1 | head -1)"
  echo "gtkwave: $(dpkg-query -W -f='${Version}' gtkwave 2>/dev/null || echo n/a)"
  echo "python3: $(python3 --version 2>&1)"
  echo "docker: $(docker --version)"
  echo "yosys image: $YOSYS_IMAGE"
  echo "yosys: $(docker run --rm "$YOSYS_IMAGE" /OpenROAD-flow-scripts/tools/install/yosys/bin/yosys -V 2>&1 | tail -1)"
  echo "opensta image: $STA_IMAGE"
  echo "opensta: $(docker run --rm --entrypoint /OpenSTA/build/sta "$STA_IMAGE" -version 2>&1 | tail -1)"
  echo "nangate45: mflowgen/freepdk-45nm@$PDK_SHA stdcells-wc.lib (operating_conditions slow: process 1.0, 0.95 V, 125 C) and stdcells.v"
} | tee "$ROOT/submission/syn_reports/tool_versions.txt"
echo "install complete"
