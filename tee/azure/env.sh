# Settings shared by the Azure scripts. Override any of them in the environment.
RG="${RG:-oft-sgx}"                       # resource group (delete it to remove everything)
LOCATION="${LOCATION:-westeurope}"        # a region with DCsv3: westeurope, northeurope, uksouth, eastus, eastus2, ...
VM="${VM:-oft-sgx}"
SIZE="${SIZE:-Standard_DC16s_v3}"         # 16 vCPU / 128 GiB / 64 GiB EPC; Standard_DC4s_v3 for the smoke test
SPOT="${SPOT:-0}"                         # 1 = spot VM (~80% cheaper, may be evicted; not allowed on free-trial subscriptions)
ADMIN="${ADMIN:-azureuser}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
AUTO_SHUTDOWN_UTC="${AUTO_SHUTDOWN_UTC:-}" # e.g. 2300: daily deallocation as a safety net
IMAGE="${IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
REMOTE_DIR="${REMOTE_DIR:-hotstuff}"       # repository location on the VM (relative to the home directory)
vm_ip() { az vm show -d -g "$RG" -n "$VM" --query publicIps -o tsv; }
