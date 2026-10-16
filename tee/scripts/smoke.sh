#!/usr/bin/env bash
# Quick functional check of every runtime available on this host: a few replicas,
# one per process/enclave, for a few seconds. Run this first on a new machine.
#
# Usage: tee/scripts/smoke.sh [runtime...]
# Environment: N (replicas, default 4), DURATION (default 10s), CONSENSUS (default oft)
set -uo pipefail
. "$(dirname "$0")/common.sh"

N="${N:-4}"
DURATION="${DURATION:-10s}"
CONSENSUS="${CONSENSUS:-oft}"
OUT="$RESULTS_DIR/smoke"
mkdir -p "$OUT" "$DATA_DIR"

runtimes=("$@")
if [ ${#runtimes[@]} -eq 0 ]; then
    # gramine-exitless is optional (two spinning host threads per enclave): pass it explicitly
    for rt in inproc native gramine-direct gramine-sgx ego-sgx ego-sim; do
        [ "$rt" = ego-sim ] && have_sgx && continue
        runtime_available "$rt" && runtimes+=("$rt")
    done
fi

status=0
printf "%-18s %-6s %8s %12s %12s %10s\n" runtime result wall_s cons_lat_ms client_lat_ms commits/s
for rt in "${runtimes[@]}"; do
    dir="$OUT/$rt"
    rm -rf "$dir"
    start=$(date +%s.%N)
    hotstuff_cmd "$rt" "$N"
    timeout --kill-after=30 1200 "${CMD[@]}" --consensus "$CONSENSUS" --clients 2 --max-concurrent 10 \
        --duration "$DURATION" --view-timeout 1s --fixed-timeout 1s \
        --metrics consensus-latency,throughput,client-latency --measurement-interval 1s \
        --log-level warn --output "$dir" >"$dir.log" 2>&1
    rc=$?
    wall=$(python3 -c "import time; print(time.time() - $start)")
    read -r cons cli thr reps <<<"$(python3 - "$dir" <<'PY'
import sys
from hsmetrics import summarize_run
s = summarize_run(sys.argv[1]) or {}
f = lambda v: "-" if v is None else f"{v:.3f}"
print(f(s.get("consensus_latency_ms")), f(s.get("client_latency_ms")), f(s.get("throughput_bps")), s.get("replicas_reporting", 0))
PY
)"
    result=PASS
    if [ $rc -ne 0 ] || [ "$cons" = - ] || [ "$cli" = - ] || [ "${reps:-0}" -lt "$N" ]; then result=FAIL; status=1; fi
    printf "%-18s %-6s %8.1f %12s %12s %10s\n" "$rt" "$result" "$wall" "$cons" "$cli" "$thr"
    [ $result = FAIL ] && { echo "  exit=$rc, see $dir.log:"; tail -5 "$dir.log" | sed 's/^/    /'; }
    kill_stray_workers
done
exit $status
