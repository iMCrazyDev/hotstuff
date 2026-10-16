#!/usr/bin/env bash
# Creates the SGX VM (Azure DCsv3, Ubuntu 24.04, Intel SGX with DCAP).
# Requires the Azure CLI, logged in (az login) to a subscription with DCSv3 quota
# in $LOCATION (check: az vm list-usage -l $LOCATION -o table | grep -i DCSv3).
set -euo pipefail
. "$(dirname "$0")/env.sh"

spot=()
[ "$SPOT" = 1 ] && spot=(--priority Spot --eviction-policy Deallocate --max-price -1)

az group create -n "$RG" -l "$LOCATION" -o none
az vm create -g "$RG" -n "$VM" -l "$LOCATION" \
    --size "$SIZE" --image "$IMAGE" \
    --admin-username "$ADMIN" --ssh-key-values "$SSH_KEY" \
    --os-disk-size-gb 64 --public-ip-sku Standard \
    "${spot[@]}" -o table
if [ -n "$AUTO_SHUTDOWN_UTC" ]; then
    az vm auto-shutdown -g "$RG" -n "$VM" --time "$AUTO_SHUTDOWN_UTC" -o none
fi
ip="$(vm_ip)"
echo
echo "VM ready: ssh $ADMIN@$ip"
echo "Next: tee/azure/sync.sh push   then on the VM: sudo -E $REMOTE_DIR/tee/scripts/setup_host.sh"
echo "Stop billing for compute when idle: tee/azure/stop_vm.sh"
