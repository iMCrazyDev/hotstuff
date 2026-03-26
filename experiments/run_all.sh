#!/bin/bash
# Run all experiments sequentially
# Usage:
#   VIEW_TIMEOUT=5s bash experiments/run_all.sh          # one timeout
#   bash experiments/run_all.sh 2s 5s                    # two timeouts
set -e

cd "$(dirname "$0")/.."
echo "Working directory: $(pwd)"

# If timeouts passed as args, use them; otherwise use VIEW_TIMEOUT env or default 5s
if [ $# -gt 0 ]; then
    TIMEOUTS="$@"
else
    TIMEOUTS="${VIEW_TIMEOUT:-5s}"
fi

for VT in $TIMEOUTS; do
    export VIEW_TIMEOUT="$VT"
    echo ""
    echo "###################################################"
    echo "  VIEW_TIMEOUT=$VT"
    echo "###################################################"

    echo "========== EXPERIMENT 1 =========="
    bash experiments/exp1_finalization.sh

    echo ""
    echo "========== EXPERIMENT 2 =========="
    bash experiments/exp2_byzantine.sh
done

echo ""
echo "========================================="
echo "  ALL DONE. Results: experiments/results/"
echo "========================================="
