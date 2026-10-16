#!/usr/bin/env bash
# Deallocates the VM: compute billing stops, the disk (and results on it) is kept.
set -euo pipefail
. "$(dirname "$0")/env.sh"
az vm deallocate -g "$RG" -n "$VM"
az vm show -d -g "$RG" -n "$VM" --query powerState -o tsv
