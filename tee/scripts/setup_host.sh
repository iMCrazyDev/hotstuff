#!/usr/bin/env bash
# Prepares an Ubuntu 24.04 host for the TEE experiments: Go, Gramine, Intel SGX
# PSW/DCAP, the Intel SGX SDK and EGo.
#
# On an SGX machine (Azure DCsv3/DCdsv3) it also configures DCAP attestation:
# Azure requires the Intel QPL to fetch PCK certificates from Azure's THIM
# service (https://learn.microsoft.com/azure/security/fundamentals/trusted-hardware-identity-management).
# On a machine without SGX it installs everything needed to test the harness
# (gramine-direct, SDK simulation mode, EGo simulation mode).
#
# Usage: sudo -E tee/scripts/setup_host.sh      (re-runnable)
set -euo pipefail

GO_VERSION="${GO_VERSION:-1.25.6}"
EGO_VERSION="${EGO_VERSION:-1.10.0}"
SGX_SDK_URL="${SGX_SDK_URL:-https://download.01.org/intel-sgx/latest/linux-latest/distro/ubuntu24.04-server/sgx_linux_x64_sdk_2.30.101.1.bin}"
TARGET_USER="${SUDO_USER:-$USER}"

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
. /etc/os-release
[ "$VERSION_CODENAME" = noble ] || echo "warning: tested on Ubuntu 24.04 (noble), this is $VERSION_CODENAME" >&2

HAVE_SGX=0
[ -c /dev/sgx_enclave ] && HAVE_SGX=1
ON_AZURE=0
curl -s -m 2 -H Metadata:true "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" >/dev/null 2>&1 && ON_AZURE=1
# Alibaba Cloud ECS (g7t/c7t/r7t SGX instances): region from the instance metadata service.
ALIYUN_REGION="$(t=$(curl -s -m 2 -X PUT -H "X-aliyun-ecs-metadata-token-ttl-seconds: 30" http://100.100.100.200/latest/api/token) \
    && curl -s -m 2 -H "X-aliyun-ecs-metadata-token: $t" http://100.100.100.200/latest/meta-data/region-id)" || ALIYUN_REGION=""
echo "== SGX device: $HAVE_SGX, Azure: $ON_AZURE, Alibaba region: ${ALIYUN_REGION:-none}"

export DEBIAN_FRONTEND=noninteractive

echo "== base packages"
apt-get update -q
apt-get install -y -q build-essential git curl jq openssl python3 python3-numpy python3-matplotlib \
    cpuid util-linux procps

echo "== Intel SGX and Gramine apt repositories"
curl -fsSLo /usr/share/keyrings/intel-sgx-deb.asc https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-sgx-deb.asc] https://download.01.org/intel-sgx/sgx_repo/ubuntu $VERSION_CODENAME main" \
    >/etc/apt/sources.list.d/intel-sgx.list
curl -fsSLo "/usr/share/keyrings/gramine-keyring-$VERSION_CODENAME.gpg" "https://packages.gramineproject.io/gramine-keyring-$VERSION_CODENAME.gpg"
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/gramine-keyring-$VERSION_CODENAME.gpg] https://packages.gramineproject.io/ $VERSION_CODENAME main" \
    >/etc/apt/sources.list.d/gramine.list
apt-get update -q

echo "== Gramine, SGX PSW and DCAP libraries"
apt-get install -y -q gramine \
    libsgx-enclave-common libsgx-urts \
    libsgx-dcap-ql libsgx-dcap-ql-dev \
    libsgx-dcap-quote-verify libsgx-dcap-quote-verify-dev \
    libsgx-dcap-default-qpl
if [ "$HAVE_SGX" = 1 ]; then
    # AESM serves quotes to Gramine (out-of-process quoting); only useful with SGX.
    apt-get install -y -q sgx-aesm-service libsgx-aesm-ecdsa-plugin libsgx-aesm-quote-ex-plugin libsgx-aesm-pce-plugin
fi

if [ "$ON_AZURE" = 1 ]; then
    echo "== QPL -> Azure THIM"
    cat >/etc/sgx_default_qcnl.conf <<'JSON'
{
  "pccs_url": "https://global.acccache.azure.net/sgx/certification/v3/",
  "use_secure_cert": true,
  "collateral_service": "https://global.acccache.azure.net/sgx/certification/v3/",
  "pccs_api_version": "3.1",
  "retry_times": 6,
  "retry_delay": 5,
  "local_pck_url": "http://169.254.169.254/metadata/THIM/sgx/certification/v3/",
  "pck_cache_expire_hours": 24,
  "verify_collateral_cache_expire_hours": 24,
  "custom_request_options": {
    "get_cert": {
      "headers": { "metadata": "true" },
      "params": { "api-version": "2021-07-22-preview" }
    }
  }
}
JSON
fi
if [ -n "$ALIYUN_REGION" ]; then
    # Alibaba's PCCS (https://www.alibabacloud.com/help/en/ecs/user-guide/build-an-sgx-encrypted-computing-environment);
    # the -vpc endpoint is reachable from inside the VPC without public traffic.
    pccs="https://sgx-dcap-server-vpc.$ALIYUN_REGION.aliyuncs.com/sgx/certification/v4/"
    curl -s -m 5 -o /dev/null "$pccs" || pccs="https://sgx-dcap-server.$ALIYUN_REGION.aliyuncs.com/sgx/certification/v4/"
    echo "== QPL -> Alibaba PCCS $pccs"
    cat >/etc/sgx_default_qcnl.conf <<JSON
{
  "pccs_url": "$pccs",
  "use_secure_cert": true,
  "collateral_service": "$pccs",
  "retry_times": 6,
  "retry_delay": 10,
  "pck_cache_expire_hours": 168,
  "verify_collateral_cache_expire_hours": 168
}
JSON
fi
if [ "$HAVE_SGX" = 1 ]; then
    systemctl enable --now aesmd || true
    systemctl restart aesmd || true
    getent group sgx >/dev/null && usermod -aG sgx "$TARGET_USER"
    getent group sgx_prv >/dev/null && usermod -aG sgx_prv "$TARGET_USER"
fi

echo "== Intel SGX SDK -> /opt/intel/sgxsdk"
if [ ! -f /opt/intel/sgxsdk/environment ]; then
    tmp="$(mktemp -d)"
    curl -fsSLo "$tmp/sdk.bin" "$SGX_SDK_URL"
    chmod +x "$tmp/sdk.bin"
    mkdir -p /opt/intel
    "$tmp/sdk.bin" --prefix=/opt/intel
    basename "$SGX_SDK_URL" >/opt/intel/sgxsdk/INSTALLED_FROM
    rm -rf "$tmp"
fi

echo "== Go >= $GO_VERSION"
have_go="$({ /usr/local/go/bin/go env GOVERSION 2>/dev/null || true; } | sed 's/^go//')"
if [ -z "$have_go" ] || [ "$(printf '%s\n%s\n' "$GO_VERSION" "$have_go" | sort -V | head -1)" != "$GO_VERSION" ]; then
    curl -fsSL "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz" | (rm -rf /usr/local/go && tar -C /usr/local -xz)
else
    echo "keeping Go $have_go"
fi
command -v go >/dev/null || ln -sf /usr/local/go/bin/go /usr/local/bin/go

echo "== EGo $EGO_VERSION"
if [ "$(dpkg-query -W -f='${Version}' ego 2>/dev/null)" != "$EGO_VERSION" ]; then
    tmp="$(mktemp -d)"
    curl -fsSLo "$tmp/ego.deb" "https://github.com/edgelesssys/ego/releases/download/v$EGO_VERSION/ego_${EGO_VERSION}_amd64_ubuntu-24.04.deb"
    apt-get install -y -q "$tmp/ego.deb"
    rm -rf "$tmp"
fi

echo "== Gramine signing key"
sudo -u "$TARGET_USER" bash -c '[ -f ~/.config/gramine/enclave-key.pem ] || gramine-sgx-gen-private-key'

echo
echo "== Done"
is-sgx-available || true
gramine-sgx --version 2>/dev/null || gramine-direct --version 2>/dev/null || true
go version
echo "EGo $(dpkg-query -W -f='${Version}' ego 2>/dev/null)"
if [ "$HAVE_SGX" = 1 ]; then
    echo
    echo "NOTE: $TARGET_USER was added to the sgx/sgx_prv groups; log out and back in before running the experiments."
fi
