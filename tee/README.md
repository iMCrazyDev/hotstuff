# OFT on real SGX hardware (Task 1)

This directory runs the replicas inside Intel SGX enclaves and measures what the
enclaves cost. It produces three deliverables:

1. **Updated Table 1**: the SGX server the experiments ran on (`table1_platform.tex`).
2. **Cost of TEE operations in microseconds**: ECALL/OCALL transitions,
   `sgx_create_report`, `sgx_verify_report`, DCAP quote generation and verification,
   enclave start-up (`teeops.tex`, `teeops.png`).
3. **Experiment 1 on SGX**: finalization latency and throughput vs. N for OFT and
   Fast-HotStuff, with every replica in its own enclave, and the overhead of
   trusted execution relative to native processes on the same server
   (`exp1_overhead.tex`, `exp1_tee_*.png`).

## How the replicas run in enclaves

`hotstuff run --replica-procs N --worker-cmd "<runtime> ..."` starts every replica as
a separate worker process through a wrapper command, so each replica gets its own
enclave. The clients stay in the controller process, outside any enclave, and
measure end-to-end latency with a single native clock. The code changes are in
`internal/orchestration/localproc.go` and the `--replica-procs`, `--worker-cmd`,
`--worker-dir`, `--worker-env` and `--proc-data-dir` flags.

| Runtime | What runs each replica | Why it is measured |
|---|---|---|
| `inproc` | goroutines of one native process | the original setup of Figures 4-5 |
| `native` | one native process | **baseline**: same process layout as the enclaves |
| `gramine-direct` | Gramine LibOS, no SGX | separates the LibOS cost from the SGX cost |
| `gramine-sgx` | Gramine-SGX enclave (LibOS, unmodified binary) | the approach the reviewers asked for |
| `ego-sgx` | EGo enclave (Go runtime built for SGX) | SGX without the LibOS penalty for Go, see below |
| `gramine-exitless` | Gramine-SGX with exitless host calls | optional: mitigation of transition costs |

**Why two enclave runtimes.** Go does not call the C library for system calls; it
issues raw `SYSCALL` instructions. Inside an SGX enclave that instruction is illegal:
Gramine catches the resulting exception and emulates the call, which costs several
enclave transitions per system call (Gramine prints *"Emulating a raw syscall
instruction. This degrades performance"*; see
[gramine#702](https://github.com/gramineproject/gramine/issues/702)). So Gramine
measures "unmodified binary in a LibOS", including the LibOS-specific penalty for
Go. EGo compiles the same code with a Go runtime that forwards system calls with
direct OCALLs, which gives the cost of SGX itself for a Go replica. Both rows are
useful in the paper, and if Gramine turns out unstable for the Go runtime on the
rented machine, EGo still yields the experiment from the same rental.

**Fairness and metrics.** Every multi-process runtime uses the same layout (one
process per replica, loopback network) and the same `GOMAXPROCS` per replica
(`WORKER_GOMAXPROCS`, default 2). Runs are interleaved over runtimes, so drifts in
machine performance affect all of them equally. The metrics are those of the
paper: block finalization latency (proposal to commit) and throughput, with the
load of `experiments/exp1_finalization.sh`. Finalization latency subtracts the
leader's proposal timestamp from the committing replica's clock, and inside SGX
these clocks are emulated by the runtime. Constant offsets between replica clocks
still cancel in the reported mean: with round-robin leaders every (leader,
replica) pair has the same weight, so each `offset_i - offset_j` term appears with
the opposite sign as well. Client latency is recorded too, but with the paper's
saturating load (4 clients × 100 outstanding commands, batch 1) it measures queueing
up to the 500 ms client timeout, so it is not used for the comparison.

## Directory layout

```
tee/
  azure/            create/start/stop/resize/delete the VM, sync code and results
  scripts/
    setup_host.sh   installs Go, Gramine, SGX PSW/DCAP (Azure THIM config), SGX SDK, EGo
    build_all.sh    static binaries, Gramine manifests, EGo enclaves, SDK microbenchmark
    smoke.sh        functional check of every runtime (N=4, 10 s)
    microbench.sh   TEE operation costs (SDK microbenchmark + teebench in each runtime)
    exp1_tee.sh     experiment 1 in each runtime (resume-safe)
    run_all.sh      all of the above in order
    analyze_tee.py  tables (Markdown, LaTeX, CSV) and figures
  gramine/          manifest template and build/sign script
  ego/              enclave config and build/sign script
  teebench/         Go microbenchmark run inside each runtime
  sgx-microbench/   C microbenchmark on the Intel SGX SDK + DCAP
```

## Running the experiment

### 0. Prerequisites (once)

> **Deadline: 1 November 2026.** Microsoft is retiring the DCsv3/DCdsv3 series, Azure's
> only SGX VMs: "Starting November 1, 2026, capacity restrictions apply to DCsv3/DCdsv3-series
> virtual machines and no new subscription is allowed"
> ([retirement guide](https://learn.microsoft.com/azure/virtual-machines/sizes/retirement/dcsv3-series-retirement)).
> Create the subscription and run the campaign before that date.

- An Azure account. A new [free account](https://azure.microsoft.com/free/) comes with
  $200 of credit for 30 days, which covers the whole campaign. The free trial is limited to
  4 vCPUs and does not allow spot VMs; upgrading to pay-as-you-go lifts the vCPU limit and
  keeps the remaining credit until day 30.
- Quota for the **Standard DCSv3 Family vCPUs** in the chosen region (4 for the smoke test,
  16 for the full run): portal → *Quotas* → *Compute*.
- Azure CLI (`brew install azure-cli`), `az login`, then `tee/azure/check_access.sh`.
- An SSH key (`~/.ssh/id_ed25519.pub`, or set `SSH_KEY`).
- A budget alert: portal → *Cost Management* → *Budgets* → $30 with e-mail alerts.

### 1. Small VM: install, build, smoke test (about 1 hour, about $0.5)

```bash
SIZE=Standard_DC4s_v3 AUTO_SHUTDOWN_UTC=2200 tee/azure/create_vm.sh
```

```bash
tee/azure/sync.sh push
```

On the VM (`ssh azureuser@<ip>`):

```bash
cd hotstuff && sudo -E tee/scripts/setup_host.sh
```

Log out and back in (the setup adds you to the `sgx` and `sgx_prv` groups), then:

```bash
cd hotstuff && tee/scripts/build_all.sh && tee/scripts/smoke.sh
```

`smoke.sh` must print `PASS` for `inproc`, `native`, `gramine-direct`, `gramine-sgx`
and `ego-sgx`. Also check `is-sgx-available`, which prints the SGX2 support and the EPC size.
If something fails, see *Troubleshooting*. The microbenchmarks can run already on
this VM: `tee/scripts/microbench.sh` (about 15 minutes).

### 2. Full run (about 10-14 hours on DC16s_v3)

```bash
SIZE=Standard_DC16s_v3 tee/azure/resize_vm.sh
```

On the VM, inside `tmux` (the run survives a dropped SSH session; re-running resumes):

```bash
cd hotstuff && tee/scripts/run_all.sh
```

Defaults: runtimes `gramine-sgx ego-sgx native inproc`, protocols `oft fasthotstuff`,
N = 5..40, 3 runs, view timeout 2 s, durations 30/60/90 s as in
`experiments/exp1_finalization.sh`. That is 4 × 2 × 8 × 3 = 192 runs. Useful overrides:

```bash
RUNTIMES="gramine-sgx native" NS="5 10 20 40" RUNS=3 tee/scripts/exp1_tee.sh
```

```bash
RUNTIMES="gramine-direct gramine-exitless" tee/scripts/exp1_tee.sh
```

### 3. Collect and stop paying

```bash
tee/azure/sync.sh pull
```

```bash
tee/azure/stop_vm.sh
```

```bash
python3 tee/scripts/analyze_tee.py experiments/results/tee
```

The tables and figures are written to `experiments/results/tee/analysis/`. Delete
the resource group when the paper is done: `tee/azure/delete_all.sh`.

### Cost

| VM | vCPU / RAM / EPC | on-demand | spot |
|---|---|---|---|
| Standard_DC4s_v3 | 4 / 32 GiB / 16 GiB | ~$0.38/h | ~$0.08/h |
| Standard_DC16s_v3 | 16 / 128 GiB / 64 GiB | ~$1.54/h | ~$0.32/h |

Prices from third-party aggregators (Vantage, Holori), East US, Linux; check the
region in the portal. The campaign is about 3 hours on DC4s_v3 and 10-14 hours on
DC16s_v3 on demand: **about $25, plus a few dollars for disk and IP**, which the free
account's credit covers. The scripts default to on-demand VMs (`SPOT=0`), which
cannot be evicted mid-run; spot (`SPOT=1`) needs a pay-as-you-go subscription and
spot quota. Deallocate the VM whenever it is idle (`tee/azure/stop_vm.sh`); a
deallocated VM costs only its disk and IP.

## Alibaba Cloud (tested)

The harness was validated on Alibaba Cloud `ecs.g7t` instances (Intel Xeon Platinum 8369B,
Ice Lake, SGX1 + SGX2 + FLC, in-kernel driver), region `cn-hongkong`, Ubuntu 24.04 (UEFI):

| Instance | vCPU | RAM for the OS | EPC |
|---|---|---|---|
| ecs.g7t.xlarge | 4 | 8 GiB | 7.75 GiB |
| ecs.g7t.4xlarge | 16 | 32 GiB | ~32 GiB |

`setup_host.sh` detects Alibaba through the instance metadata service and points the Intel
QPL at Alibaba's PCCS (`https://sgx-dcap-server-vpc.<region>.aliyuncs.com/sgx/certification/v4/`),
so DCAP quote generation and verification work out of the box. Create the instance as
pay-as-you-go from the console, then run `setup_host.sh`, `build_all.sh` and `smoke.sh` as
above. To resize, stop the instance in normal mode (economical mode may release the
public IP), change the instance type and start it again.

Gramine-SGX enclaves with EDMM take about 45 s of CPU each to start on these VMs: the EDMM
ioctls (`REMOVE_PAGES`, `MODIFY_TYPES`, `RESTRICT_PERMISSIONS`) trigger enclave-wide
TLB shootdowns, which are expensive under KVM. This is a one-time cost per replica:
steady-state finalization latency with EDMM was within 3-4% of fixed-size enclaves
(N=3, 30 s runs), so EDMM stays on, as it is the only way to fit 40 enclaves in the EPC.
`--worker-start-timeout` (30 min for the TEE runtimes) and the per-run limit of
`exp1_tee.sh` account for it.

## Enclave configuration

- **Gramine** (`gramine/go-app.manifest.template`): on SGX2 CPUs (the Ice Lake CPUs of
  DCsv3 are SGX2) the manifest enables EDMM, so enclave memory is committed on use
  and 40 enclaves fit in the EPC. Without SGX2 it falls back to fixed 4 GiB enclaves
  (`ENCLAVE_SIZE`). 64 enclave threads (`MAX_THREADS`), production (non-debug) enclaves,
  DCAP attestation enabled. The manifest is printed with its MRENCLAVE at build time.
- **EGo** (`ego/enclave.json.in`): 512 MiB heap per enclave (`HEAP_MB`), production mode.
  A replica process uses about 50 MiB of memory and at most 9 threads at N=40
  (measured natively), so 40 enclaves need 20 GiB of EPC.
- **SGX SDK microbenchmark** (`sgx-microbench/`): production enclave signed with a
  locally generated key (allowed on Azure, which has Flexible Launch Control).

## What the numbers mean (for the paper text)

- *Enclave transition*: `ecall_empty` / `ocall_empty` from the SDK microbenchmark are
  the raw hardware cost of entering and leaving an enclave.
- *Report generation*: `report_create` is `sgx_create_report` (EREPORT) inside the
  enclave; `report_create_ecall` is what an application pays for one report including
  the ECALL. *Report verification* is `sgx_verify_report`.
- *Remote attestation*: `quote_generate` is a DCAP quote (report for the Quoting
  Enclave + QE signature). `quote_verify_collateral` is the pure verification cost
  with collateral already fetched; `quote_verify` serves collateral from the QPL
  cache; `quote_verify_first` includes fetching the collateral from Azure THIM.
  Quote verification results such as `OUT_OF_DATE` or `SW_HARDENING_NEEDED` are TCB
  policy statuses of the cloud platform, not failures; they are recorded in the JSON.
- Attestation happens once per replica when it joins the membership, not on the
  consensus critical path. The experiment-1 overhead is the steady-state cost of
  running the protocol engine inside the enclave.

Limitations to state honestly:

- The controller still generates the replicas' signing keys and passes them to the
  enclaves at start-up, as in the original framework. For the performance
  measurements this makes no difference; generating keys inside the enclave and
  binding them to the quote's report data is needed for the equivocation
  experiment (Task 2).
- Command-line arguments are passed from the host
  (`loader.insecure__use_cmdline_argv`); they carry no secrets.
- All replicas share one host and a loopback network, as in Figures 4-5, which
  isolates the enclave cost from network latency.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `smoke.sh`: gramine-sgx FAIL, log shows `Out of memory` / `enclave_size` | `ENCLAVE_SIZE=8G` (no EDMM) or check `is-sgx-available` shows SGX2; rebuild with `tee/scripts/build_all.sh` |
| `Too many threads` / `could not create thread` in Gramine | `MAX_THREADS=128 tee/scripts/build_all.sh` |
| N=40 hangs at start-up | not enough EPC: `dmesg | grep sgx`; use DC24s_v3, lower `HEAP_MB` (EGo) or keep EDMM on (Gramine) |
| `sgx_qe_get_target_info failed` / quote errors | `systemctl status aesmd`; `/etc/sgx_default_qcnl.conf` must point to THIM (setup does this on Azure); user in `sgx_prv` group (re-login) |
| `Permission denied` on `/dev/sgx_enclave` | re-login after `setup_host.sh`, or `sudo usermod -aG sgx $USER` |
| Gramine prints `Emulating a raw syscall instruction` | expected for Go, this is the LibOS penalty described above |
| A run failed | `cat experiments/results/tee/exp1_tee/timeout_2s/<rt>/<p>/N<n>/run<r>/run.log`; delete the `run<r>.attempts` file to retry it |

## Testing without SGX

On any Ubuntu 24.04 machine, `setup_host.sh` installs everything except the AESM
service, `build_all.sh` builds the SDK microbenchmark in simulation mode, and
`smoke.sh` / `exp1_tee.sh` / `microbench.sh` run `inproc`, `native`, `gramine-direct`
and `ego-sim` (EGo simulation). This validates the harness and the analysis
end to end; SGX numbers need the real machine.
