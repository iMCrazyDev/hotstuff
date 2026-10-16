#!/usr/bin/env bash
# Changes the VM size, e.g. from DC4s_v3 (smoke test) to DC16s_v3 (full run).
# Usage: SIZE=Standard_DC16s_v3 tee/azure/resize_vm.sh
set -euo pipefail
. "$(dirname "$0")/env.sh"
az vm deallocate -g "$RG" -n "$VM"
az vm resize -g "$RG" -n "$VM" --size "$SIZE" -o none
az vm start -g "$RG" -n "$VM"
echo "resized to $SIZE: ssh $ADMIN@$(vm_ip)"
