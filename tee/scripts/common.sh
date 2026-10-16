# Shared settings for the TEE experiment scripts. Sourced, not executed.
TEE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$TEE_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$TEE_DIR/build}"
BIN_DIR="$BUILD_DIR/bin"
DATA_DIR="${DATA_DIR:-/var/tmp/hotstuff-tee}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/experiments/results/tee}"
# GOMAXPROCS of every replica process (the same in every runtime, for a fair comparison).
WORKER_GOMAXPROCS="${WORKER_GOMAXPROCS:-2}"
export PATH="/usr/local/go/bin:$PATH"
export DATA_DIR
export PYTHONPATH="$TEE_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}"

have_sgx() { [ -c /dev/sgx_enclave ]; }
have() { command -v "$1" >/dev/null 2>&1; }

# runtime_args <runtime>: sets RT_ARGS to the hotstuff run flags that start the
# replicas in the given runtime, one replica per process (except "inproc").
#   inproc           all replicas as goroutines of one native process (original setup of Figures 4-5)
#   native           one native process per replica
#   gramine-direct   one Gramine LibOS process per replica, without SGX
#   gramine-sgx      one Gramine SGX enclave per replica
#   gramine-exitless one Gramine SGX enclave per replica, exitless host calls
#   ego-sgx          one EGo SGX enclave per replica
#   ego-sim          EGo in simulation mode (no SGX; for testing the harness only)
runtime_args() {
    local env="GOMAXPROCS=$WORKER_GOMAXPROCS"
    case "$1" in
    inproc) RT_ARGS=() ;;
    native) RT_ARGS=(--worker-cmd "$BIN_DIR/hotstuff" --worker-env "$env") ;;
    gramine-direct) RT_ARGS=(--worker-dir "$BUILD_DIR/gramine/direct" --worker-cmd "gramine-direct hotstuff") ;;
    gramine-sgx) RT_ARGS=(--worker-dir "$BUILD_DIR/gramine/sgx" --worker-cmd "gramine-sgx hotstuff") ;;
    gramine-exitless) RT_ARGS=(--worker-dir "$BUILD_DIR/gramine/sgx-exitless" --worker-cmd "gramine-sgx hotstuff") ;;
    ego-sgx) RT_ARGS=(--worker-dir "$BUILD_DIR/ego" --worker-cmd "ego run hotstuff-ego") ;;
    ego-sim) RT_ARGS=(--worker-dir "$BUILD_DIR/ego" --worker-cmd "ego run hotstuff-ego"); env="$env,OE_SIMULATION=1" ;;
    *) echo "unknown runtime: $1" >&2; return 1 ;;
    esac
    case "$1" in
    gramine-* | ego-*) RT_ARGS+=(--proc-data-dir "$DATA_DIR" --worker-env "$env" --worker-start-timeout 30m) ;;
    esac
}

# hotstuff_cmd <runtime> <replicas>: sets CMD to the hotstuff run command line
# that starts <replicas> replicas in the given runtime; append further flags.
hotstuff_cmd() {
    local runtime="$1" n="$2"
    runtime_args "$runtime" || return 1
    CMD=("$BIN_DIR/hotstuff" run --replicas "$n")
    [ "$runtime" != inproc ] && CMD+=(--replica-procs "$n")
    CMD+=("${RT_ARGS[@]}")
}

# kill_stray_workers: removes worker processes left behind by a failed run.
kill_stray_workers() {
    pkill -f -- ' worker --connect 127\.0\.0\.1:' 2>/dev/null || true
    sleep 1
    pkill -9 -f -- ' worker --connect 127\.0\.0\.1:' 2>/dev/null || true
}

# runtime_available <runtime>: whether the runtime can run on this host.
runtime_available() {
    case "$1" in
    inproc | native) [ -x "$BIN_DIR/hotstuff" ] ;;
    gramine-direct) have gramine-direct && [ -f "$BUILD_DIR/gramine/direct/hotstuff.manifest" ] ;;
    gramine-sgx) have_sgx && [ -f "$BUILD_DIR/gramine/sgx/hotstuff.manifest.sgx" ] ;;
    gramine-exitless) have_sgx && [ -f "$BUILD_DIR/gramine/sgx-exitless/hotstuff.manifest.sgx" ] ;;
    ego-sgx) have_sgx && have ego && [ -f "$BUILD_DIR/ego/hotstuff-ego" ] ;;
    ego-sim) have ego && [ -f "$BUILD_DIR/ego/hotstuff-ego" ] ;;
    *) return 1 ;;
    esac
}
