#!/bin/bash
# Experiment 1: Block finalization time vs number of participants N
# Measures consensus latency (propose → commit) for OFT
# For each N, collects K = N * 100 blocks

set -e

BINARY="./hotstuff"
OUTDIR="experiments/results/exp1"
CONSENSUS="oft"
BATCH_SIZE=1
MAX_CONCURRENT=50
CLIENTS=2
MEASUREMENT_INTERVAL="1s"

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 1: Finalization Time vs N"
echo "  Consensus: $CONSENSUS"
echo "============================================="

for N in 4 7 10 13 16; do
    K=$((N * 100))

    # scale timeout and duration by N
    if [ $N -le 7 ]; then
        DURATION="10s"
        VIEW_TIMEOUT="5s"
    elif [ $N -le 10 ]; then
        DURATION="20s"
        VIEW_TIMEOUT="5s"
    else
        DURATION="30s"
        VIEW_TIMEOUT="5s"
    fi

    RUN_DIR="$OUTDIR/N${N}"
    rm -rf "$RUN_DIR"

    echo ""
    echo "--- N=$N (need K=$K blocks, duration=$DURATION, timeout=$VIEW_TIMEOUT) ---"

    $BINARY run \
        --consensus "$CONSENSUS" \
        --replicas "$N" \
        --clients "$CLIENTS" \
        --max-concurrent "$MAX_CONCURRENT" \
        --batch-size "$BATCH_SIZE" \
        --duration "$DURATION" \
        --view-timeout "$VIEW_TIMEOUT" \
        --fixed-timeout "$VIEW_TIMEOUT" \
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
    K = N * 100
    json_path = os.path.join('$OUTDIR', f'N{N}', 'local', 'measurements.json')
    if not os.path.exists(json_path):
        continue

    with open(json_path) as f:
        data = json.load(f)

    total_lat = 0.0
    total_var = 0.0
    total_count = 0

    for entry in data:
        if entry.get('@type', '') == 'type.googleapis.com/types.LatencyMeasurement':
            count = int(entry.get('Count', '0'))
            lat = float(entry.get('Latency', 0))
            var = entry.get('Variance', 0)
            if isinstance(var, str) and var == 'NaN':
                continue
            var = float(var)
            if count > 0:
                total_lat += lat * count
                total_var += var * count
                total_count += count

    if total_count > 0:
        avg_lat = total_lat / total_count
        avg_var = total_var / total_count
        std_dev = math.sqrt(avg_var)
        unique_blocks = total_count // N
    else:
        avg_lat = None
        std_dev = None
        unique_blocks = 0

    results.append({
        'N': N,
        'target_K': K,
        'avg_latency_ms': round(avg_lat, 4) if avg_lat else None,
        'std_dev_ms': round(std_dev, 4) if std_dev else None,
        'unique_blocks': unique_blocks,
        'total_samples': total_count,
    })

summary = {
    'experiment': 'exp1_finalization_time_vs_N',
    'consensus': '$CONSENSUS',
    'batch_size': $BATCH_SIZE,
    'clients': $CLIENTS,
    'max_concurrent': $MAX_CONCURRENT,
    'results': results,
}

with open('$SUMMARY', 'w') as f:
    json.dump(summary, f, indent=2)

print(json.dumps(summary, indent=2))
"

echo ""
echo "Done! Summary: $SUMMARY"
echo "Raw data: $OUTDIR/N*/local/measurements.json"
