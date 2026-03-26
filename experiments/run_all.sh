#!/bin/bash
# Run all experiments sequentially
# Usage: VIEW_TIMEOUT=5s bash experiments/run_all.sh
set -e

export VIEW_TIMEOUT="${VIEW_TIMEOUT:-5s}"

cd "$(dirname "$0")/.."
echo "Working directory: $(pwd)"
echo "VIEW_TIMEOUT=$VIEW_TIMEOUT"
echo ""

echo "========== EXPERIMENT 1 =========="
bash experiments/exp1_finalization.sh

echo ""
echo "========== EXPERIMENT 2 =========="
bash experiments/exp2_byzantine.sh

echo ""
echo "========================================="
echo "  ALL DONE. Results: experiments/results/"
echo "========================================="
