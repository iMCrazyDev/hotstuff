#!/bin/bash
# Experiment 2: Block finalization time vs N with Byzantine fork-attackers
# FastHotStuff only, f = floor((N-1)/3) faulty nodes, multiple runs
# Skips already completed runs (resume-safe)

set -e

BINARY="./hotstuff"
OUTDIR="experiments/results/exp2/timeout_${VIEW_TIMEOUT}"
CONSENSUS="fasthotstuff"
BATCH_SIZE=1
MAX_CONCURRENT=100
CLIENTS=4
MEASUREMENT_INTERVAL="1s"
RUNS=3

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 2: Finalization Time vs N"
echo "  FastHotStuff + Byzantine fork ($RUNS runs)"
echo "  View timeout: $VIEW_TIMEOUT (fixed)"
echo "============================================="

for N in $(seq 5 5 40); do
    F=$(( (N - 1) / 3 ))

    BYZ_IDS=""
    for i in $(seq $((N - F + 1)) $N); do
        if [ -z "$BYZ_IDS" ]; then
            BYZ_IDS="$i"
        else
            BYZ_IDS="$BYZ_IDS, $i"
        fi
    done

    if [ $N -le 10 ]; then
        DURATION="60s"
    elif [ $N -le 20 ]; then
        DURATION="90s"
    else
        DURATION="120s"
    fi

    CUE_FILE="$OUTDIR/N${N}.cue"
    cat > "$CUE_FILE" <<CUEEOF
package config

config: {
    replicaHosts: ["localhost"]
    clientHosts:  ["localhost"]
    replicas:     $N
    clients:      $CLIENTS
    consensus:    "$CONSENSUS"
    crypto:       "ecdsa"
    leaderRotation: "round-robin"
    communication:  "clique"
    byzantineStrategy: {fork: [$BYZ_IDS]}
}
CUEEOF

    for R in $(seq 1 $RUNS); do
        RUN_DIR="$OUTDIR/N${N}/run${R}"
        MFILE="$RUN_DIR/local/measurements.json"

        if [ -f "$MFILE" ]; then
            echo "[skip] N=$N f=$F run=$R (already done)"
            continue
        fi

        rm -rf "$RUN_DIR"
        echo "--- N=$N f=$F run=$R/$RUNS duration=$DURATION ---"

        $BINARY run \
            --cue "$CUE_FILE" \
            --max-concurrent "$MAX_CONCURRENT" \
            --batch-size "$BATCH_SIZE" \
            --duration "$DURATION" \
            --view-timeout "$VIEW_TIMEOUT" \
            --fixed-timeout "$VIEW_TIMEOUT" \
            --log-level info \
            --metrics consensus-latency,throughput \
            --measurement-interval "$MEASUREMENT_INTERVAL" \
            --output "$RUN_DIR" \
            2>&1 | tail -3
    done
done

echo ""
echo "=== Aggregating ==="

python3 -c "
import json, math, os, statistics

RUNS = $RUNS
results = []

for N in list(range(5, 41, 5)):
    f = (N - 1) // 3
    run_lats = []
    run_thrs = []

    for r in range(1, RUNS + 1):
        path = os.path.join('$OUTDIR', f'N{N}', f'run{r}', 'local', 'measurements.json')
        if not os.path.exists(path):
            continue
        with open(path) as f_in:
            data = json.load(f_in)

        total_lat = 0.0
        total_count = 0
        total_commits = 0
        total_duration = 0.0

        for entry in data:
            t = entry.get('@type', '')
            if t == 'type.googleapis.com/types.LatencyMeasurement':
                count = int(entry.get('Count', '0'))
                lat = float(entry.get('Latency', 0))
                if count > 0:
                    total_lat += lat * count
                    total_count += count
            elif t == 'type.googleapis.com/types.ThroughputMeasurement':
                commits = int(entry.get('Commits', '0'))
                dur = entry.get('Duration', '0s')
                if isinstance(dur, str) and dur.endswith('s'):
                    total_commits += commits
                    total_duration += float(dur[:-1])

        if total_count > 0:
            run_lats.append(total_lat / total_count)
        if total_duration > 0:
            run_thrs.append(total_commits / total_duration)

    if not run_lats:
        continue

    avg_lat = statistics.mean(run_lats)
    std_lat = statistics.stdev(run_lats) if len(run_lats) > 1 else 0.0
    avg_thr = statistics.mean(run_thrs) if run_thrs else None
    std_thr = statistics.stdev(run_thrs) if len(run_thrs) > 1 else 0.0

    results.append({
        'N': N,
        'f_byzantine': f,
        'runs': len(run_lats),
        'avg_latency_ms': round(avg_lat, 4),
        'std_dev_ms': round(std_lat, 4),
        'avg_throughput_bps': round(avg_thr, 2) if avg_thr else None,
        'std_throughput_bps': round(std_thr, 2),
    })

summary = {
    'experiment': 'exp2_byzantine_finalization_time_vs_N',
    'consensus': '$CONSENSUS',
    'byzantine_strategy': 'fork',
    'runs_per_config': RUNS,
    'view_timeout': '$VIEW_TIMEOUT',
    'batch_size': $BATCH_SIZE,
    'clients': $CLIENTS,
    'max_concurrent': $MAX_CONCURRENT,
    'results': results,
}

with open('$OUTDIR/summary.json', 'w') as f_out:
    json.dump(summary, f_out, indent=2)

print(json.dumps(summary, indent=2))
"

echo "Done! Summary: $OUTDIR/summary.json"
