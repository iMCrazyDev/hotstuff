"""Parsing of hotstuff measurement files, shared by the TEE scripts.

A run directory holds one measurements.json per worker: local/ (clients, and all
replicas in "inproc" mode) and proc<i>/ (one per replica process). Latency
events are split by origin: replica events give the consensus latency (block
proposal to commit, measured with the clocks of two replicas), client events
give the end-to-end latency of a command (measured with one native clock, so
it is the robust metric when comparing runtimes).
"""
import glob
import json
import os

LATENCY = "type.googleapis.com/types.LatencyMeasurement"
THROUGHPUT = "type.googleapis.com/types.ThroughputMeasurement"


def _seconds(duration):
    return float(duration[:-1]) if isinstance(duration, str) and duration.endswith("s") else 0.0


def summarize_run(run_dir):
    """Returns weighted mean latencies (ms), counts and throughput of one run, or None."""
    files = glob.glob(os.path.join(run_dir, "*", "measurements.json"))
    if not files:
        return None
    rep_sum = rep_n = cli_sum = cli_n = 0.0
    commits = 0
    duration = 0.0
    replicas = set()
    per_second = {}  # commits of all replicas per wall-clock second
    for path in files:
        try:
            with open(path) as f:
                entries = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        for e in entries:
            t = e.get("@type", "")
            ev = e.get("Event", {})
            if t == LATENCY:
                n = int(e.get("Count", "0"))
                if n == 0:
                    continue
                lat = float(e.get("Latency", 0))
                if ev.get("Client"):
                    cli_sum += lat * n
                    cli_n += n
                else:
                    rep_sum += lat * n
                    rep_n += n
                    replicas.add(ev.get("ID"))
            elif t == THROUGHPUT:
                c = int(e.get("Commits", "0"))
                commits += c
                duration += _seconds(e.get("Duration"))
                replicas.add(ev.get("ID"))
                sec = ev.get("Timestamp", "")[:19]
                per_second[sec] = per_second.get(sec, 0) + c
    # Liveness: seconds without any commit in the middle of the run, and at its end.
    # A long dead tail means consensus stopped and never recovered.
    series = [per_second[s] for s in sorted(per_second)]
    active = [i for i, c in enumerate(series) if c > 0]
    dead_mid = sum(1 for c in series[active[0]:active[-1] + 1] if c == 0) if active else len(series)
    dead_tail = len(series) - 1 - active[-1] if active else len(series)
    return {
        "run_seconds": len(series),
        "dead_mid_s": dead_mid,
        "dead_tail_s": dead_tail,
        "stalled": dead_tail >= max(10, 0.2 * len(series)),
        "consensus_latency_ms": rep_sum / rep_n if rep_n else None,
        "consensus_latency_count": int(rep_n),
        "client_latency_ms": cli_sum / cli_n if cli_n else None,
        "client_latency_count": int(cli_n),
        # Same definition as experiments/exp1_finalization.sh: commits per second, averaged over replicas.
        "throughput_bps": commits / duration if duration else None,
        "replicas_reporting": len(replicas),
    }


if __name__ == "__main__":
    import sys

    for d in sys.argv[1:]:
        print(d, json.dumps(summarize_run(d)))
