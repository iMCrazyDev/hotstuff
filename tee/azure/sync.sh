#!/usr/bin/env bash
# push: copies the repository (without results and build outputs) to the VM.
# pull: copies experiments/results/tee back from the VM.
# Usage: tee/azure/sync.sh push|pull
set -euo pipefail
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
host="$ADMIN@$(vm_ip)"
case "${1:-}" in
push)
    rsync -az --delete --exclude .git --exclude 'experiments/results' --exclude 'tee/build' \
        --exclude 'tee/sgx-microbench/microbench' --exclude '*.so' --exclude '/hotstuff' --exclude '/plot' \
        "$REPO/" "$host:$REMOTE_DIR/" ;;
pull)
    mkdir -p "$REPO/experiments/results/tee"
    rsync -az "$host:$REMOTE_DIR/experiments/results/tee/" "$REPO/experiments/results/tee/" ;;
*)
    echo "usage: $0 push|pull" >&2; exit 2 ;;
esac
