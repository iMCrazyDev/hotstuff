#!/bin/bash
# Experiment 2: Block finalization time vs N with Byzantine nodes (FastHotStuff only)
# f = floor((N-1)/3) faulty nodes use "silentproposer" strategy
# Uses CUE configs to assign byzantine strategy to specific replica IDs

set -e

BINARY="./hotstuff"
OUTDIR="experiments/results/exp2"
CONSENSUS="fasthotstuff"
BATCH_SIZE=1
MAX_CONCURRENT=50
CLIENTS=2
MEASUREMENT_INTERVAL="1s"

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 2: Finalization Time vs N"
echo "  with Byzantine nodes (FastHotStuff)"
echo "============================================="

for N in 4 7 10 13 16; do
    F=$(( (N - 1) / 3 ))

    # build list of byzantine replica IDs: last f replicas
    BYZ_IDS=""
    for i in $(seq $((N - F + 1)) $N); do
        if [ -z "$BYZ_IDS" ]; then
            BYZ_IDS="$i"
        else
            BYZ_IDS="$BYZ_IDS, $i"
        fi
    done

    # scale duration by N (need longer with timeouts from silent leaders)
    # use default 500ms view-timeout so silent leader views resolve quickly
    if [ $N -le 7 ]; then
        DURATION="30s"
    elif [ $N -le 10 ]; then
        DURATION="45s"
    else
        DURATION="60s"
    fi

    RUN_DIR="$OUTDIR/N${N}"
    rm -rf "$RUN_DIR"
    CUE_FILE="$OUTDIR/N${N}.cue"

    echo ""
    echo "--- N=$N, f=$F byzantine (IDs: $BYZ_IDS), duration=$DURATION ---"

    # generate CUE config
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
    byzantineStrategy: {silentproposer: [$BYZ_IDS]}
}
CUEEOF

    $BINARY run \
        --cue "$CUE_FILE" \
        --max-concurrent "$MAX_CONCURRENT" \
        --batch-size "$BATCH_SIZE" \
        --duration "$DURATION" \
        --log-level info \
        --metrics consensus-latency,throughput \
        --measurement-interval "$MEASUREMENT_INTERVAL" \
        --output "$RUN_DIR" \
        2>&1 | grep -E "Done sending|Stopping"

    echo "  Output: $RUN_DIR"
done

echo ""
echo "============================================="
echo "  Aggregating results to JSON..."
echo "============================================="

SUMMARY="$OUTDIR/summary.json"

python3 -c "
import json, math, os

results = []
for N in [4, 7, 10, 13, 16]:
    f = (N - 1) // 3
    json_path = os.path.join('$OUTDIR', f'N{N}', 'local', 'measurements.json')
    if not os.path.exists(json_path):
        continue

    with open(json_path) as f_in:
        data = json.load(f_in)

    total_lat = 0.0
    total_var = 0.0
    total_count = 0
    total_commits = 0
    total_duration = 0.0

    for entry in data:
        t = entry.get('@type', '')
        if t == 'type.googleapis.com/types.LatencyMeasurement':
            count = int(entry.get('Count', '0'))
            lat = float(entry.get('Latency', 0))
            v = entry.get('Variance', 0)
            if isinstance(v, str) and v == 'NaN':
                continue
            v = float(v)
            if count > 0:
                total_lat += lat * count
                total_var += v * count
                total_count += count
        elif t == 'type.googleapis.com/types.ThroughputMeasurement':
            commits = int(entry.get('Commits', '0'))
            dur = entry.get('Duration', '0s')
            if isinstance(dur, str) and dur.endswith('s'):
                total_commits += commits
                total_duration += float(dur[:-1])

    if total_count > 0:
        avg_lat = total_lat / total_count
        avg_var = total_var / total_count
        std_dev = math.sqrt(avg_var)
        unique_blocks = total_count // N
    else:
        avg_lat = None
        std_dev = None
        unique_blocks = 0

    if total_duration > 0:
        avg_throughput = total_commits / total_duration
    else:
        avg_throughput = None

    results.append({
        'N': N,
        'f_byzantine': f,
        'avg_latency_ms': round(avg_lat, 4) if avg_lat else None,
        'std_dev_ms': round(std_dev, 4) if std_dev else None,
        'unique_blocks': unique_blocks,
        'total_samples': total_count,
        'avg_throughput_bps': round(avg_throughput, 2) if avg_throughput else None,
    })

summary = {
    'experiment': 'exp2_byzantine_finalization_time_vs_N',
    'consensus': '$CONSENSUS',
    'byzantine_strategy': 'silentproposer',
    'batch_size': $BATCH_SIZE,
    'clients': $CLIENTS,
    'max_concurrent': $MAX_CONCURRENT,
    'results': results,
}

with open('$SUMMARY', 'w') as f_out:
    json.dump(summary, f_out, indent=2)

print(json.dumps(summary, indent=2))
"

echo ""
echo "Done! Summary: $SUMMARY"
echo "Raw data: $OUTDIR/N*/local/measurements.json"
