#!/bin/bash
# Experiment 2: Block finalization time vs N with Byzantine fork-attackers
# FastHotStuff only, N=3f+1, Byzantine IDs evenly spaced in leader rotation
# Iterates by f, not N
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
DURATION="240s"

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 2: Finalization Time vs N"
echo "  FastHotStuff + Byzantine fork ($RUNS runs)"
echo "  N = 3f+1, Byzantine evenly spaced (step=N/f)"
echo "  View timeout: $VIEW_TIMEOUT (fixed)"
echo "  Duration: $DURATION per run"
echo "============================================="

for F in 1 2 3 4 5; do
    N=$(( 3 * F + 1 ))

    # Byzantine replicas: evenly spaced by step=N/f so ~every 3rd leader is faulty
    # Leader rotation is round-robin: leader(v) = (v % N) + 1
    # IDs 1, 1+step, 1+2*step, ... give gaps of ~3 views between Byzantine leaders
    STEP=$((N / F))
    BYZ_IDS=""
    for k in $(seq 0 $((F - 1))); do
        ID=$((k * STEP + 1))
        if [ -z "$BYZ_IDS" ]; then
            BYZ_IDS="$ID"
        else
            BYZ_IDS="$BYZ_IDS, $ID"
        fi
    done

    echo ""
    echo "--- f=$F N=$N byzantine IDs: [$BYZ_IDS] ---"

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
            echo "[skip] f=$F N=$N run=$R (already done)"
            continue
        fi

        rm -rf "$RUN_DIR"
        echo "--- f=$F N=$N run=$R/$RUNS duration=$DURATION ---"

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

for f in range(1, 6):
    N = 3 * f + 1
    run_lats = []
    run_thrs = []

    for r in range(1, RUNS + 1):
        path = os.path.join('$OUTDIR', f'N{N}', f'run{r}', 'local', 'measurements.json')
        if not os.path.exists(path):
            continue
        try:
            with open(path) as f_in:
                data = json.load(f_in)
        except json.JSONDecodeError:
            print(f'WARN: skipping corrupt {path}')
            continue

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
    'byzantine_placement': 'evenly_spaced_step_N_div_f',
    'runs_per_config': RUNS,
    'duration': '$DURATION',
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
