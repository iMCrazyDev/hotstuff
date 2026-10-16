#!/usr/bin/env bash
# Experiment 1 on real TEE hardware: block finalization latency and throughput
# vs. N for OFT and Fast-HotStuff, with every replica in its own process and,
# for the TEE runtimes, its own SGX enclave.
#
# Runtimes (see common.sh): native is the baseline every TEE runtime is compared
# against (same process layout, same GOMAXPROCS); inproc reproduces the original
# single-process setup of Figures 4-5.
#
# Runs are interleaved (for each run index and N, all protocols and runtimes in
# turn), so slow drifts of the machine affect all runtimes equally. The script is
# resume-safe: finished runs are skipped, failed runs are retried up to
# MAX_ATTEMPTS times and then given up.
#
# Usage: tee/scripts/exp1_tee.sh
# Environment (defaults reproduce experiments/exp1_finalization.sh):
#   RUNTIMES      default: the TEE runtimes available here + native + inproc
#   PROTOCOLS     "oft fasthotstuff"
#   NS            "5 10 15 20 25 30 35 40"
#   RUNS          3
#   VIEW_TIMEOUT  2s
#   DURATION      fixed run duration; default 30s (N<=10), 60s (N<=20), 90s (N>20)
#   CLIENTS=4 BATCH_SIZE=1 MAX_CONCURRENT=100 MAX_ATTEMPTS=2
set -uo pipefail
. "$(dirname "$0")/common.sh"

PROTOCOLS="${PROTOCOLS:-oft fasthotstuff}"
NS="${NS:-5 10 15 20 25 30 35 40}"
RUNS="${RUNS:-3}"
VIEW_TIMEOUT="${VIEW_TIMEOUT:-2s}"
CLIENTS="${CLIENTS:-4}"
BATCH_SIZE="${BATCH_SIZE:-1}"
MAX_CONCURRENT="${MAX_CONCURRENT:-100}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
OUT="$RESULTS_DIR/exp1_tee/timeout_$VIEW_TIMEOUT"

if [ -z "${RUNTIMES:-}" ]; then
    RUNTIMES=""
    for rt in gramine-sgx ego-sgx native inproc; do
        runtime_available "$rt" && RUNTIMES="$RUNTIMES $rt"
    done
fi
for rt in $RUNTIMES; do
    runtime_available "$rt" || { echo "runtime $rt is not available on this host" >&2; exit 1; }
done

duration_for() {
    if [ -n "${DURATION:-}" ]; then echo "$DURATION"
    elif [ "$1" -le 10 ]; then echo 30s
    elif [ "$1" -le 20 ]; then echo 60s
    else echo 90s; fi
}
seconds() { local d="$1"; echo "${d%s}"; }

mkdir -p "$OUT" "$DATA_DIR"
cat >"$OUT/config.json" <<EOF
{"runtimes": "$(echo $RUNTIMES)", "protocols": "$PROTOCOLS", "ns": "$NS", "runs": $RUNS,
 "view_timeout": "$VIEW_TIMEOUT", "clients": $CLIENTS, "batch_size": $BATCH_SIZE,
 "max_concurrent": $MAX_CONCURRENT, "worker_gomaxprocs": $WORKER_GOMAXPROCS, "duration": "${DURATION:-30s/60s/90s}"}
EOF

total=0
for R in $(seq 1 "$RUNS"); do for N in $NS; do for P in $PROTOCOLS; do for RT in $RUNTIMES; do
    total=$((total + 1))
done; done; done; done
echo "exp1_tee: runtimes=[$RUNTIMES] protocols=[$PROTOCOLS] N=[$NS] runs=$RUNS timeout=$VIEW_TIMEOUT -> $total runs, results in $OUT"

i=0
for R in $(seq 1 "$RUNS"); do
    for N in $NS; do
        for P in $PROTOCOLS; do
            for RT in $RUNTIMES; do
                i=$((i + 1))
                dir="$OUT/$RT/$P/N$N/run$R"
                if [ -f "$dir/done" ]; then continue; fi
                attempts=$(cat "$dir.attempts" 2>/dev/null || echo 0)
                if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
                    echo "[$i/$total] give up $RT $P N=$N run=$R ($attempts failed attempts)"
                    continue
                fi
                D="$(duration_for "$N")"
                # experiment + 5 view timeouts of drain + enclave start-up allowance
                # (Gramine-SGX with EDMM needs ~45 s of CPU per enclave to start in a VM)
                limit=$(($(seconds "$D") + 5 * $(seconds "$VIEW_TIMEOUT") + 2100))
                rm -rf "$dir"
                mkdir -p "$dir"
                echo "[$i/$total] $RT $P N=$N run=$R duration=$D (attempt $((attempts + 1)))"
                hotstuff_cmd "$RT" "$N"
                start=$(date +%s)
                timeout --kill-after=30 "$limit" "${CMD[@]}" \
                    --consensus "$P" \
                    --clients "$CLIENTS" \
                    --max-concurrent "$MAX_CONCURRENT" \
                    --batch-size "$BATCH_SIZE" \
                    --duration "$D" \
                    --view-timeout "$VIEW_TIMEOUT" \
                    --fixed-timeout "$VIEW_TIMEOUT" \
                    --log-level warn \
                    --metrics consensus-latency,throughput,client-latency \
                    --measurement-interval 1s \
                    --output "$dir" >"$dir/run.log" 2>&1
                rc=$?
                end=$(date +%s)
                kill_stray_workers
                summary="$(python3 -c "import json,sys; from hsmetrics import summarize_run; print(json.dumps(summarize_run(sys.argv[1])))" "$dir")"
                echo "{\"runtime\": \"$RT\", \"protocol\": \"$P\", \"n\": $N, \"run\": $R, \"duration\": \"$D\", \"exit_code\": $rc, \"wall_seconds\": $((end - start)), \"summary\": $summary}" >"$dir/meta.json"
                reporting=$(python3 -c "import json,sys; s=json.load(open(sys.argv[1]))['summary'] or {}; print(s.get('replicas_reporting', 0) if s.get('client_latency_ms') else 0)" "$dir/meta.json")
                if [ "$rc" -eq 0 ] && [ "$reporting" -ge "$N" ]; then
                    touch "$dir/done"
                    rm -f "$dir.attempts"
                    echo "    ok in $((end - start))s: $summary"
                else
                    echo $((attempts + 1)) >"$dir.attempts"
                    echo "    FAILED (exit=$rc, replicas reporting=$reporting/$N), log tail:"
                    tail -5 "$dir/run.log" | sed 's/^/      /'
                fi
                rm -f "$DATA_DIR"/*-proc*.json
            done
        done
    done
done
echo "exp1_tee done: $OUT"
