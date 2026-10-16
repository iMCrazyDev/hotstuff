#!/usr/bin/env bash
# The whole TEE campaign on one SGX host, in order:
#   platform info -> build -> smoke test -> microbenchmarks -> experiment 1 -> analysis.
# Every step is resume-safe; run it inside tmux (or with nohup) and re-run after an interruption.
#
# Usage: tee/scripts/run_all.sh            (environment variables of the steps apply)
set -uo pipefail
. "$(dirname "$0")/common.sh"
S="$TEE_DIR/scripts"
mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/run_all.log"
exec > >(tee -a "$LOG") 2>&1

echo "===== $(date -u +%FT%TZ) run_all on $(hostname)"
"$S/build_all.sh" || exit 1
"$S/platform_info.sh" "$RESULTS_DIR" >/dev/null
echo "===== smoke"
"$S/smoke.sh" || { echo "smoke test failed; fix before spending hours on the experiment"; exit 1; }
echo "===== microbenchmarks"
[ -f "$RESULTS_DIR/teeops/startup.json" ] || "$S/microbench.sh"
echo "===== experiment 1"
"$S/exp1_tee.sh"
echo "===== analysis"
python3 "$S/analyze_tee.py" "$RESULTS_DIR"
echo "===== $(date -u +%FT%TZ) done; copy $RESULTS_DIR back before deallocating the VM"
