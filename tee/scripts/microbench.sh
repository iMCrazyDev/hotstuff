#!/usr/bin/env bash
# TEE operation microbenchmarks (the table of real microseconds):
#   1. SGX SDK microbenchmark: raw ECALL/OCALL, sgx_create_report, sgx_verify_report,
#      DCAP quote generation and verification (hardware mode on SGX hosts).
#   2. teebench in every runtime: syscalls with and without an enclave exit,
#      network round trips, ECDSA, and attestation through Gramine/EGo.
#   3. Verification of the quotes produced by Gramine and EGo with the DCAP QVL.
#   4. Enclave start-up time (one-time cost per replica).
#
# Usage: tee/scripts/microbench.sh
# Environment: SAMPLES (10000), SLOW_SAMPLES (300), STARTUP_REPS (5), RUNTIMES
set -uo pipefail
. "$(dirname "$0")/common.sh"

SAMPLES="${SAMPLES:-10000}"
SLOW_SAMPLES="${SLOW_SAMPLES:-300}"
STARTUP_REPS="${STARTUP_REPS:-5}"
OUT="$RESULTS_DIR/teeops"
mkdir -p "$OUT" "$DATA_DIR"

if [ -z "${RUNTIMES:-}" ]; then
    RUNTIMES=""
    for rt in native gramine-direct gramine-sgx ego-sgx ego-sim; do
        [ "$rt" = ego-sim ] && have_sgx && continue
        runtime_available "$rt" && RUNTIMES="$RUNTIMES $rt"
    done
fi

# teebench_cmd <runtime>: sets DIR and CMD to run teebench in the runtime.
teebench_cmd() {
    case "$1" in
    native) DIR="$BIN_DIR"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" ./teebench) ;;
    gramine-direct) DIR="$BUILD_DIR/gramine/direct"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" gramine-direct teebench) ;;
    gramine-sgx) DIR="$BUILD_DIR/gramine/sgx"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" gramine-sgx teebench) ;;
    gramine-exitless) DIR="$BUILD_DIR/gramine/sgx-exitless"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" gramine-sgx teebench) ;;
    ego-sgx) DIR="$BUILD_DIR/ego"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" ego run teebench-ego) ;;
    ego-sim) DIR="$BUILD_DIR/ego"; CMD=(env GOMAXPROCS="$WORKER_GOMAXPROCS" OE_SIMULATION=1 ego run teebench-ego) ;;
    *) return 1 ;; # e.g. inproc: same process type as native, nothing separate to measure
    esac
}

if [ -x "$TEE_DIR/sgx-microbench/microbench" ]; then
    echo "== SGX SDK microbenchmark ($(cat "$TEE_DIR/sgx-microbench/.mode" 2>/dev/null))"
    # the SDK environment provides the simulation libraries (hardware mode uses the PSW's)
    (. /opt/intel/sgxsdk/environment && cd "$TEE_DIR/sgx-microbench" && ./microbench --samples "$SAMPLES" --slow-samples "$SLOW_SAMPLES" \
        --out "$OUT/sgx-sdk.json" --quote-out "$OUT/quote-sgx-sdk.bin") 2>&1 | tee "$OUT/sgx-sdk.log"
fi

for rt in $RUNTIMES; do
    teebench_cmd "$rt" || continue
    echo "== teebench: $rt"
    rm -f "$DATA_DIR/teebench.json" "$DATA_DIR/quote.bin"
    (cd "$DIR" && timeout 3600 "${CMD[@]}" -runtime "$rt" -samples "$SAMPLES" -slow-samples "$SLOW_SAMPLES" \
        -out "$DATA_DIR/teebench.json" -quote-out "$DATA_DIR/quote.bin") 2>&1 | tee "$OUT/teebench-$rt.log"
    [ -f "$DATA_DIR/teebench.json" ] && mv "$DATA_DIR/teebench.json" "$OUT/teebench-$rt.json"
    [ -s "$DATA_DIR/quote.bin" ] && mv "$DATA_DIR/quote.bin" "$OUT/quote-$rt.bin"
done

if [ -x "$TEE_DIR/sgx-microbench/microbench" ] && have_sgx; then
    for q in "$OUT"/quote-gramine-sgx.bin "$OUT"/quote-ego-sgx.bin; do
        [ -s "$q" ] || continue
        label="$(basename "$q" .bin)"
        label="${label#quote-}"
        echo "== DCAP verification of the $label quote"
        (. /opt/intel/sgxsdk/environment && cd "$TEE_DIR/sgx-microbench" && ./microbench verify "$q" --label "$label" \
            --slow-samples "$SLOW_SAMPLES" --out "$OUT/verify-$label.json") 2>&1 | tee "$OUT/verify-$label.log"
    done
fi

echo "== enclave start-up time ($STARTUP_REPS repetitions)"
{
    echo "["
    first=1
    for rt in $RUNTIMES; do
        teebench_cmd "$rt" || continue
        for r in $(seq 1 "$STARTUP_REPS"); do
            start=$(date +%s%N)
            (cd "$DIR" && "${CMD[@]}" -ops none -out - >/dev/null 2>&1)
            rc=$?
            ns=$(($(date +%s%N) - start))
            [ $first = 1 ] || echo ","
            first=0
            printf '{"runtime": "%s", "rep": %d, "exit_code": %d, "ns": %d}' "$rt" "$r" "$rc" "$ns"
            echo "  $rt rep $r: $((ns / 1000000)) ms (exit $rc)" >&2
        done
    done
    echo "]"
} >"$OUT/startup.json"
echo "microbench done: $OUT"
