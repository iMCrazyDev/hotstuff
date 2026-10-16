| Parameter | Value |
|---|---|
| Platform | Alibaba Cloud ecs.g7t.4xlarge (cn-hongkong) |
| CPU | Intel(R) Xeon(R) Platinum 8369B CPU @ 2.70GHz, 16 vCPUs |
| Memory | 30 GiB RAM, EPC 31 GiB |
| TEE | Intel SGX (SGX1, SGX2, FLC), hardware enclaves, DCAP attestation |
| OS / kernel | Ubuntu 24.04.5 LTS, Linux 6.8.0-139-generic |
| Enclave runtimes | Gramine 1.9; EGo 1.10.0 |
| SGX SDK / DCAP | sgx_linux_x64_sdk_2.30.101.1.bin; DCAP 1.27.101.1-noble1 |
| Language runtime | go1.25.6 linux/amd64 |
| Deployment | single host, one process (enclave) per replica, loopback network, GOMAXPROCS=2 per replica |
