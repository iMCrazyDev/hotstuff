#!/usr/bin/env bash
# Checks that the subscription can create the SGX VM in $LOCATION: which DCsv3
# sizes are offered there (an empty "restrictions" column means usable) and
# how much vCPU quota is available. Run it right after `az login`.
set -euo pipefail
. "$(dirname "$0")/env.sh"

echo "== subscription"
az account show --query "{name:name, id:id, state:state}" -o table
echo
echo "== DCsv3 sizes in $LOCATION"
az vm list-skus -l "$LOCATION" --resource-type virtualMachines --size Standard_DC --all \
    --query "[?ends_with(name, 's_v3') && !contains(name, 'ds_')].{size:name, restrictions:join(', ', restrictions[].reasonCode)}" \
    -o table
echo
echo "== vCPU quota in $LOCATION (need DCSv3 >= 4 for the smoke test, >= 16 for the full run)"
az vm list-usage -l "$LOCATION" \
    --query "[?name.value=='standardDCSv3Family' || name.value=='cores' || name.value=='lowPriorityCores'].{quota:localName, used:currentValue, limit:limit}" \
    -o table
