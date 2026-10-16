#!/usr/bin/env bash
# Starts a deallocated VM; prints its (possibly new) address.
set -euo pipefail
. "$(dirname "$0")/env.sh"
az vm start -g "$RG" -n "$VM"
echo "ssh $ADMIN@$(vm_ip)"
