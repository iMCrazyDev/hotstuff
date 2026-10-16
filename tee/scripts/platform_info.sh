#!/usr/bin/env bash
# Records the platform the experiments run on (for Table 1): CPU, SGX features,
# EPC size, kernel, VM size and software versions.
# Usage: tee/scripts/platform_info.sh [out_dir]
set -uo pipefail
. "$(dirname "$0")/common.sh"
OUT="${1:-$RESULTS_DIR}"
mkdir -p "$OUT"

imds() { curl -s -m 2 -H Metadata:true "http://169.254.169.254/metadata/instance/compute/$1?api-version=2021-02-01&format=text"; }
aliyun_md() {
    local t
    t=$(curl -s -m 2 -X PUT -H "X-aliyun-ecs-metadata-token-ttl-seconds: 30" http://100.100.100.200/latest/api/token) || return 0
    curl -s -m 2 -H "X-aliyun-ecs-metadata-token: $t" "http://100.100.100.200/latest/meta-data/$1"
}
pkgver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }

{
    echo "### date";        date -u +%FT%TZ
    echo "### lscpu";       lscpu
    echo "### cpu flags";   grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(sgx|sgx_lc|sgx2|constant_tsc|nonstop_tsc|tsc_known_freq|avx512f)' | sort -u
    echo "### is-sgx-available"; is-sgx-available 2>&1
    echo "### sgx dmesg";   (dmesg 2>/dev/null || sudo -n dmesg 2>/dev/null) | grep -i sgx
    echo "### memory";      free -g
    echo "### kernel";      uname -a
    echo "### os";          cat /etc/os-release
    echo "### azure";       echo "vmSize=$(imds vmSize) location=$(imds location)"
    echo "### aliyun";      echo "instanceType=$(aliyun_md instance/instance-type) region=$(aliyun_md region-id) zone=$(aliyun_md zone-id)"
    echo "### versions"
    echo "go=$(go version 2>/dev/null)"
    echo "gramine=$(pkgver gramine)"
    echo "ego=$(pkgver ego)"
    echo "sgx_sdk=$(cat /opt/intel/sgxsdk/INSTALLED_FROM 2>/dev/null)"
    echo "libsgx-enclave-common=$(pkgver libsgx-enclave-common)"
    echo "libsgx-dcap-ql=$(pkgver libsgx-dcap-ql)"
    echo "libsgx-dcap-quote-verify=$(pkgver libsgx-dcap-quote-verify)"
    echo "sgx-aesm-service=$(pkgver sgx-aesm-service)"
    echo "### build variants"
    cat "$BUILD_DIR"/gramine/*/variant.txt "$BUILD_DIR"/ego/variant.txt 2>/dev/null
    echo "### worker GOMAXPROCS"; echo "$WORKER_GOMAXPROCS"
} >"$OUT/platform.txt" 2>&1

python3 - "$OUT/platform.txt" "$OUT/platform.json" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
parts = re.split(r'^### (.+)$', text, flags=re.M)
sections = {title.strip(): body.strip("\n") for title, body in zip(parts[1::2], parts[2::2])}
def find(pattern, src, default=""):
    m = re.search(pattern, src, re.M)
    return m.group(1).strip() if m else default
lscpu, sgx, vers, az = sections.get('lscpu', ''), sections.get('is-sgx-available', ''), sections.get('versions', ''), sections.get('azure', '')
ali = sections.get('aliyun', '')
epc = find(r'EPC size:\s*(\S+)', sgx)
info = {
    "cpu_model": find(r'^Model name:\s*(.+)$', lscpu),
    "vcpus": find(r'^CPU\(s\):\s*(\d+)', lscpu),
    "threads_per_core": find(r'^Thread\(s\) per core:\s*(\d+)', lscpu),
    "hypervisor": find(r'^Hypervisor vendor:\s*(.+)$', lscpu),
    "memory_gib": find(r'^Mem:\s+(\d+)', sections.get('memory', '')),
    "sgx1": find(r'^SGX1.*:\s*(\w+)', sgx),
    "sgx2": find(r'^SGX2.*:\s*(\w+)', sgx),
    "flc": find(r'^Flexible Launch Control.*:\s*(\w+)', sgx),
    "epc_size_bytes": int(epc, 16) if epc.startswith('0x') else epc,
    "kernel": find(r'^Linux \S+ (\S+)', sections.get('kernel', '')),
    "os": find(r'^PRETTY_NAME="(.+)"', sections.get('os', '')),
    "azure_vm_size": find(r'vmSize=(\S*)', az),
    "azure_location": find(r'location=(\S*)', az),
    "aliyun_instance_type": find(r'instanceType=(\S*)', ali),
    "aliyun_region": find(r'region=(\S*)', ali),
    "versions": dict(l.split('=', 1) for l in vers.strip().splitlines() if '=' in l),
    "build_variants": sections.get('build variants', '').strip().splitlines(),
    "worker_gomaxprocs": sections.get('worker GOMAXPROCS', '').strip(),
}
json.dump(info, open(sys.argv[2], 'w'), indent=2)
print(json.dumps(info, indent=2))
PY
