#!/usr/bin/env bash
# Builds everything the TEE experiments need:
#   - static hotstuff and teebench binaries (native, and inside Gramine),
#   - Gramine manifests (direct; sgx and sgx-exitless on SGX hosts),
#   - EGo enclaves (if ego is installed),
#   - the SGX SDK microbenchmark (hardware mode on SGX hosts, simulation otherwise).
set -euo pipefail
. "$(dirname "$0")/common.sh"

mkdir -p "$BIN_DIR"
echo "== Go binaries (static)"
(cd "$REPO_DIR" && CGO_ENABLED=0 go build -trimpath -o "$BIN_DIR/hotstuff" ./cmd/hotstuff)
(cd "$TEE_DIR/teebench" && CGO_ENABLED=0 go build -trimpath -o "$BIN_DIR/teebench" .)

if have gramine-manifest; then
    echo "== Gramine manifests"
    variants=(direct)
    have_sgx && variants+=(sgx sgx-exitless)
    BIN_DIR="$BIN_DIR" OUT_DIR="$BUILD_DIR/gramine" "$TEE_DIR/gramine/build.sh" "${variants[@]}"
else
    echo "== Gramine not installed, skipping"
fi

if have ego-go; then
    echo "== EGo enclaves"
    OUT_DIR="$BUILD_DIR/ego" "$TEE_DIR/ego/build.sh"
else
    echo "== EGo not installed, skipping"
fi

if [ -f /opt/intel/sgxsdk/environment ]; then
    echo "== SGX SDK microbenchmark"
    mode=SIM
    have_sgx && mode=HW
    (
        . /opt/intel/sgxsdk/environment
        cd "$TEE_DIR/sgx-microbench"
        [ -f .mode ] && [ "$(cat .mode)" != "$mode" ] && make clean
        make SGX_MODE="$mode"
        echo "$mode" >.mode
    )
else
    echo "== SGX SDK not installed, skipping the microbenchmark"
fi
echo "== build done"
