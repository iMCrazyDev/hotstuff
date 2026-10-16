#!/usr/bin/env bash
# Deletes the resource group: the VM, its disk and everything on it. Pull the results first.
set -euo pipefail
. "$(dirname "$0")/env.sh"
read -r -p "Delete resource group $RG and all its resources? Type the group name: " answer
[ "$answer" = "$RG" ] || { echo "aborted"; exit 1; }
az group delete -n "$RG" --yes
