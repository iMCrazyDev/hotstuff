#!/usr/bin/env bash
# Renders and signs the Gramine manifests for hotstuff and teebench.
#
# Usage: tee/gramine/build.sh <variant>...
#   direct         gramine-direct: Gramine LibOS without SGX (isolates the LibOS cost)
#   sgx            gramine-sgx; EDMM when the CPU supports SGX2 (override with EDMM=0|1)
#   sgx-exitless   gramine-sgx with exitless host calls (RPC_THREADS untrusted threads per enclave)
#
# Environment:
#   BIN_DIR        static Go binaries (default: tee/build/bin)
#   OUT_DIR        output directory (default: tee/build/gramine)
#   DATA_DIR       host directory shared with the enclaves (default: /var/tmp/hotstuff-tee)
#   EDMM           auto|0|1 (default: auto)
#   ENCLAVE_SIZE   enclave size; default 64G with EDMM (reserved lazily), 4G without
#   MAX_THREADS    enclave threads (default: 64)
#   RPC_THREADS    exitless threads for sgx-exitless (default: 2)
#   SGX_DEBUG      true|false (default: false)
#   LOG_LEVEL      Gramine log level (default: error)
#   SGX_SIGNER_KEY signing key (default: ~/.config/gramine/enclave-key.pem, generated if missing)
set -euo pipefail

TEE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${BIN_DIR:-$TEE_DIR/build/bin}"
OUT_DIR="${OUT_DIR:-$TEE_DIR/build/gramine}"
DATA_DIR="${DATA_DIR:-/var/tmp/hotstuff-tee}"
EDMM="${EDMM:-auto}"
MAX_THREADS="${MAX_THREADS:-64}"
RPC_THREADS="${RPC_THREADS:-2}"
SGX_DEBUG="${SGX_DEBUG:-false}"
LOG_LEVEL="${LOG_LEVEL:-error}"
SGX_SIGNER_KEY="${SGX_SIGNER_KEY:-$HOME/.config/gramine/enclave-key.pem}"
TEMPLATE="$TEE_DIR/gramine/go-app.manifest.template"

[ $# -gt 0 ] || { sed -n '2,20p' "$0"; exit 2; }

if [ "$EDMM" = auto ]; then
    if is-sgx-available 2>/dev/null | grep -Eq '^SGX2.*: true'; then EDMM=1; else EDMM=0; fi
fi

mkdir -p "$DATA_DIR"
chmod 1777 "$DATA_DIR" 2>/dev/null || true

render() { # variant app edmm enclave_size rpc_threads ra
    local dir="$OUT_DIR/$1" app="$2"
    mkdir -p "$dir"
    gramine-manifest \
        -Dbinary="$BIN_DIR/$app" \
        -Ddata_dir="$DATA_DIR" \
        -Dlog_level="$LOG_LEVEL" \
        -Dstack_size=2M \
        -Ddebug="$SGX_DEBUG" \
        -Dedmm="$3" \
        -Denclave_size="$4" \
        -Dmax_threads="$MAX_THREADS" \
        -Drpc_threads="$5" \
        -Dremote_attestation="$6" \
        "$TEMPLATE" "$dir/$app.manifest"
}

sign() { # variant app
    local dir="$OUT_DIR/$1"
    if [ ! -f "$SGX_SIGNER_KEY" ]; then
        mkdir -p "$(dirname "$SGX_SIGNER_KEY")"
        gramine-sgx-gen-private-key "$SGX_SIGNER_KEY"
    fi
    gramine-sgx-sign --key "$SGX_SIGNER_KEY" \
        --manifest "$dir/$2.manifest" --output "$dir/$2.manifest.sgx" >"$dir/$2.sign.log"
    echo "$1/$2 MRENCLAVE: $(grep -iA1 '^Measurement:' "$dir/$2.sign.log" | tail -1 | tr -d ' ')"
}

for variant in "$@"; do
    case "$variant" in
    direct)
        for app in hotstuff teebench; do render direct "$app" false 4G 0 none; done ;;
    sgx | sgx-exitless)
        rpc=0
        [ "$variant" = sgx-exitless ] && rpc="$RPC_THREADS"
        if [ "$EDMM" = 1 ]; then edmm=true; size="${ENCLAVE_SIZE:-64G}"; else edmm=false; size="${ENCLAVE_SIZE:-4G}"; fi
        for app in hotstuff teebench; do
            render "$variant" "$app" "$edmm" "$size" "$rpc" dcap
            sign "$variant" "$app"
        done
        echo "$variant: edmm=$edmm enclave_size=$size max_threads=$MAX_THREADS rpc_threads=$rpc debug=$SGX_DEBUG" \
            | tee "$OUT_DIR/$variant/variant.txt" ;;
    *)
        echo "unknown variant: $variant" >&2; exit 2 ;;
    esac
done
