# Experiment 1 on Intel SGX: results

Collected on 2026-10-15/16 with `tee/scripts/run_all.sh` (see `tee/README.md`).

- Platform: Alibaba Cloud `ecs.g7t.4xlarge` (cn-hongkong), Intel Xeon Platinum 8369B (Ice Lake),
  16 vCPUs, 30 GiB RAM, 31 GiB EPC, SGX1 + SGX2 + FLC, Ubuntu 24.04, Linux 6.8 — `platform.json`.
- Runtimes: `inproc`, `native`, `gramine-direct`, `gramine-sgx` (Gramine 1.9), `ego-sgx` (EGo 1.10).
- Protocols: OFT and Fast-HotStuff; N = 5..40; 3 runs each; view timeout 2 s; 240 runs, none failed.

## Layout

| Path | Content |
|---|---|
| `analysis/` | tables (Markdown, LaTeX, CSV) and figures produced by `tee/scripts/analyze_tee.py` |
| `teeops/` | TEE operation microbenchmarks: SGX SDK (`sgx-sdk.json`), teebench per runtime, DCAP verification of Gramine and EGo quotes, enclave start-up times |
| `teeops-superseded/` | first EGo teebench run, timed per operation with EGo's 1 ms in-enclave clock; replaced by the batched run in `teeops/` |
| `exp1_tee/timeout_2s/<runtime>/<protocol>/N<n>/run<r>/` | per run: `meta.json` (summary, exit code, wall time), `hosts.json`, `done` |
| `exp1_tee_raw_measurements.tar.xz` | the raw `measurements.json` of every worker of every run |
| `exp1_tee_run_logs.tar.xz` | the controller and worker logs (`run.log`) of every run |
| `platform.*`, `run_all.log`, `setup.log`, `build.log` | platform information and campaign logs (enclave MRENCLAVEs are in `build.log`) |

## Reproducing the analysis

```bash
tar -xJf exp1_tee_raw_measurements.tar.xz
python3 ../../../tee/scripts/analyze_tee.py .
```

## Notes

- Gramine-SGX + OFT at N=35 (2 of 3 runs) and N=40 (3 of 3 runs): consensus stopped after
  ~15 s and never recovered (`stalled_runs` in `analysis/exp1_tee.csv`; crosses in the figures).
  The single 16-vCPU host is overloaded by 40 Gramine enclaves (Go system calls trap in
  Gramine-SGX: ~14 µs each), messages arrive after the 2 s view timeout, and OFT's
  timeout-driven view change does not re-synchronize the replicas' views. Fast-HotStuff on the
  same configuration only shows short pauses.
- Quote verification status of the platform: `CONFIG_AND_SW_HARDENING_NEEDED` (signature
  verified; platform TCB not at the latest level).
