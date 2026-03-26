#!/bin/bash
# Experiment 1: Block finalization time vs N
# OFT vs FastHotStuff, multiple runs per N for averaging

set -e

BINARY="./hotstuff"
OUTDIR="experiments/results/exp1/timeout_${VIEW_TIMEOUT}"
BATCH_SIZE=1
MAX_CONCURRENT=100
CLIENTS=4
MEASUREMENT_INTERVAL="1s"
RUNS=3

mkdir -p "$OUTDIR"

echo "============================================="
echo "  Experiment 1: Finalization Time vs N"
echo "  OFT vs FastHotStuff ($RUNS runs each)"
echo "  View timeout: $VIEW_TIMEOUT (fixed)"
echo "============================================="

for CONSENSUS in oft fasthotstuff; do
    echo ""
    echo "=== Protocol: $CONSENSUS ==="

    for N in $(seq 5 5 50); do
        if [ $N -le 10 ]; then
            DURATION="30s"
        elif [ $N -le 20 ]; then
            DURATION="60s"
        elif [ $N -le 35 ]; then
            DURATION="90s"
        else
            DURATION="120s"
        fi

        for R in $(seq 1 $RUNS); do
            RUN_DIR="$OUTDIR/${CONSENSUS}/N${N}/run${R}"
            rm -rf "$RUN_DIR"
            echo "--- $CONSENSUS N=$N run=$R/$RUNS duration=$DURATION ---"

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
                2>&1 | tail -3
        done
    done
done

echo ""
echo "=== Aggregating ==="

python3 -c "
import json, math, os, statistics

RUNS = $RUNS
all_results = {}

for consensus in ['oft', 'fasthotstuff']:
    results = []
    for N in list(range(5, 51, 5)):
        run_lats = []
        run_thrs = []
        for r in range(1, RUNS + 1):
            path = os.path.join('$OUTDIR', consensus, f'N{N}', f'run{r}', 'local', 'measurements.json')
            if not os.path.exists(path):
                continue
            with open(path) as f:
                data = json.load(f)

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
            'runs': len(run_lats),
            'avg_latency_ms': round(avg_lat, 4),
            'std_dev_ms': round(std_lat, 4),
            'avg_throughput_bps': round(avg_thr, 2) if avg_thr else None,
            'std_throughput_bps': round(std_thr, 2),
        })

    all_results[consensus] = results

summary = {
    'experiment': 'exp1_finalization_time_vs_N',
    'protocols': ['oft', 'fasthotstuff'],
    'runs_per_config': RUNS,
    'view_timeout': '$VIEW_TIMEOUT',
    'batch_size': $BATCH_SIZE,
    'clients': $CLIENTS,
    'max_concurrent': $MAX_CONCURRENT,
    'results': all_results,
}

with open('$OUTDIR/summary.json', 'w') as f:
    json.dump(summary, f, indent=2)

print(json.dumps(summary, indent=2))
"

echo "Done! Summary: $OUTDIR/summary.json"
