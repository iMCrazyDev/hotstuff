#!/bin/bash
# Experiment 1: Block finalization time vs number of participants N
# Compares OFT (1-chain, f+1 quorum) vs FastHotStuff (2-chain, 2f+1 quorum)
# For each N, collects K = N * 100 blocks

set -e

BINARY="./hotstuff"
OUTDIR="experiments/results/exp1"
BATCH_SIZE=1
MAX_CONCURRENT=50
CLIENTS=2
MEASUREMENT_INTERVAL="1s"

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 1: Finalization Time vs N"
echo "  OFT vs FastHotStuff"
echo "============================================="

for CONSENSUS in oft fasthotstuff; do
    echo ""
    echo "============================================="
    echo "  Protocol: $CONSENSUS"
    echo "============================================="

    for N in 4 7 10 13 16; do
        K=$((N * 100))

        # scale duration by N
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

        RUN_DIR="$OUTDIR/${CONSENSUS}/N${N}"
        rm -rf "$RUN_DIR"

        echo ""
        echo "--- $CONSENSUS N=$N (need K=$K blocks, duration=$DURATION) ---"

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
done

echo ""
echo "============================================="
echo "  Aggregating results to JSON..."
echo "============================================="

SUMMARY="$OUTDIR/summary.json"

python3 -c "
import json, math, os

all_results = {}

for consensus in ['oft', 'fasthotstuff']:
    results = []
    for N in [4, 7, 10, 13, 16]:
        K = N * 100
        json_path = os.path.join('$OUTDIR', consensus, f'N{N}', 'local', 'measurements.json')
        if not os.path.exists(json_path):
            continue

        with open(json_path) as f:
            data = json.load(f)

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
                # parse duration like '1.000131292s'
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

        # throughput: average across all replicas
        if total_duration > 0:
            avg_throughput = total_commits / total_duration
        else:
            avg_throughput = None

        results.append({
            'N': N,
            'target_K': K,
            'avg_latency_ms': round(avg_lat, 4) if avg_lat else None,
            'std_dev_ms': round(std_dev, 4) if std_dev else None,
            'unique_blocks': unique_blocks,
            'total_samples': total_count,
            'avg_throughput_bps': round(avg_throughput, 2) if avg_throughput else None,
        })

    all_results[consensus] = results

summary = {
    'experiment': 'exp1_finalization_time_vs_N',
    'protocols': ['oft', 'fasthotstuff'],
    'batch_size': $BATCH_SIZE,
    'clients': $CLIENTS,
    'max_concurrent': $MAX_CONCURRENT,
    'results': all_results,
}

with open('$SUMMARY', 'w') as f:
    json.dump(summary, f, indent=2)

print(json.dumps(summary, indent=2))
"

echo ""
echo "Done! Summary: $SUMMARY"
echo "Raw data: $OUTDIR/{oft,fasthotstuff}/N*/local/measurements.json"
