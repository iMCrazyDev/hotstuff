#!/usr/bin/env bash
# Builds and signs the EGo enclaves for hotstuff and teebench.
# EGo compiles Go programs with a modified runtime that forwards system calls to
# the host with direct OCALLs, instead of trapping raw SYSCALL instructions as a
# LibOS must do for Go binaries.
#
# Usage: tee/ego/build.sh
# Environment:
#   OUT_DIR    output directory (default: tee/build/ego)
#   DATA_DIR   host directory shared with the enclaves (default: /var/tmp/hotstuff-tee)
#   HEAP_MB    enclave heap in MiB (default: 512; a replica uses ~50 MiB at N=40)
#   SGX_DEBUG  true|false (default: false)
# Run with: (cd tee/build/ego && ego run hotstuff-ego ...); add OE_SIMULATION=1 without SGX.
set -euo pipefail

TEE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$TEE_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$TEE_DIR/build/ego}"
DATA_DIR="${DATA_DIR:-/var/tmp/hotstuff-tee}"
HEAP_MB="${HEAP_MB:-512}"
SGX_DEBUG="${SGX_DEBUG:-false}"

mkdir -p "$OUT_DIR" "$DATA_DIR"
chmod 1777 "$DATA_DIR" 2>/dev/null || true

(cd "$REPO_DIR" && ego-go build -trimpath -o "$OUT_DIR/hotstuff-ego" ./cmd/hotstuff)
(cd "$TEE_DIR/teebench" && ego-go build -trimpath -tags ego -o "$OUT_DIR/teebench-ego" .)

cd "$OUT_DIR"
for exe in hotstuff-ego teebench-ego; do
    sed -e "s|@EXE@|$exe|" -e "s|@DEBUG@|$SGX_DEBUG|" -e "s|@HEAP_MB@|$HEAP_MB|" -e "s|@DATA_DIR@|$DATA_DIR|g" \
        "$TEE_DIR/ego/enclave.json.in" >"$exe.json"
    ego sign "$exe.json"
    ego uniqueid "$exe" 2>/dev/null | sed "s/^/$exe mrenclave: /" || true
done
echo "heap=${HEAP_MB}MiB debug=$SGX_DEBUG" >"$OUT_DIR/variant.txt"
