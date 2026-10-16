#!/usr/bin/env python3
"""Turns the TEE campaign results into the paper's tables and figures.

Usage: analyze_tee.py [results_dir]   (default: experiments/results/tee)

Inputs (written by the other scripts in tee/scripts):
  platform.json                         platform_info.sh
  teeops/*.json, teeops/startup.json    microbench.sh
  exp1_tee/timeout_*/<runtime>/<protocol>/N<n>/run<r>/meta.json   exp1_tee.sh

Outputs in <results_dir>/analysis/:
  table1_platform.{md,tex}     updated Table 1 (experimental platform)
  teeops.{md,tex,csv}          TEE operation costs in microseconds
  exp1_tee.{md,csv}            per runtime/protocol/N means and standard deviations
  exp1_overhead.{md,tex,csv}   overhead of each TEE runtime over native processes
  *.png / *.pdf                figures (if matplotlib is available)
"""
import csv
import glob
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hsmetrics import summarize_run  # noqa: E402

RUNTIME_LABELS = {
    "inproc": "single process (native)",
    "native": "native process / replica",
    "gramine-direct": "Gramine LibOS, no SGX",
    "gramine-sgx": "Gramine-SGX enclave / replica",
    "gramine-exitless": "Gramine-SGX exitless",
    "ego-sgx": "EGo-SGX enclave / replica",
    "ego-sim": "EGo simulation",
    "sgx-sdk-hw": "SGX SDK (C, hardware)",
    "sgx-sdk-sim": "SGX SDK (C, simulation)",
    "sgx-sdk-verify": "DCAP QVL (C)",
}
RUNTIME_ORDER = ["inproc", "native", "gramine-direct", "gramine-sgx", "gramine-exitless", "ego-sgx", "ego-sim"]
TEE_RUNTIMES = ["gramine-direct", "gramine-sgx", "gramine-exitless", "ego-sgx", "ego-sim"]
PROTOCOL_LABELS = {"oft": "OFT", "fasthotstuff": "Fast-HotStuff"}


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def us(ns):
    return None if ns is None else ns / 1e3


def fmt(v, digits=2):
    if v is None:
        return "–"
    if abs(v) >= 1000:
        return f"{v:,.0f}"
    if abs(v) >= 100:
        return f"{v:.0f}"
    if abs(v) >= 10:
        return f"{v:.1f}"
    return f"{v:.{digits}f}"


def write_md(path, header, rows):
    with open(path, "w") as f:
        f.write("| " + " | ".join(header) + " |\n")
        f.write("|" + "|".join("---" for _ in header) + "|\n")
        for r in rows:
            f.write("| " + " | ".join(str(c) for c in r) + " |\n")


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def tex_escape(s):
    return str(s).replace("_", r"\_").replace("%", r"\%").replace("&", r"\&").replace("#", r"\#")


def write_tex(path, header, rows, caption, label, align=None):
    align = align or "l" * len(header)
    with open(path, "w") as f:
        f.write("\\begin{table}[t]\n\\centering\n\\small\n")
        f.write(f"\\caption{{{caption}}}\n\\label{{{label}}}\n")
        f.write(f"\\begin{{tabular}}{{{align}}}\n\\toprule\n")
        f.write(" & ".join(tex_escape(h) for h in header) + " \\\\\n\\midrule\n")
        for r in rows:
            f.write(" & ".join(tex_escape(c) for c in r) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n\\end{table}\n")


# ---------------------------------------------------------------- Table 1


def table_platform(res, out):
    p = load_json(os.path.join(res, "platform.json"))
    if not p:
        print("no platform.json, skipping Table 1")
        return
    v = p.get("versions", {})
    epc = p.get("epc_size_bytes")
    epc_s = f"{epc / 2**30:.0f} GiB" if isinstance(epc, int) else (epc or "–")
    sgx = ", ".join(k.upper() for k in ("sgx1", "sgx2", "flc") if p.get(k) == "true") or "none"
    rows = [
        ("Platform", f"Azure {p['azure_vm_size']} ({p['azure_location']})" if p.get("azure_vm_size")
                     else f"Alibaba Cloud {p['aliyun_instance_type']} ({p['aliyun_region']})" if p.get("aliyun_instance_type")
                     else "bare metal / other"),
        ("CPU", f"{p.get('cpu_model', '–')}, {p.get('vcpus', '–')} vCPUs"),
        ("Memory", f"{p.get('memory_gib', '–')} GiB RAM, EPC {epc_s}"),
        ("TEE", f"Intel SGX ({sgx}), hardware enclaves, DCAP attestation"),
        ("OS / kernel", f"{p.get('os', '–')}, Linux {p.get('kernel', '–')}"),
        ("Enclave runtimes", f"Gramine {v.get('gramine') or '–'}; EGo {v.get('ego') or '–'}"),
        ("SGX SDK / DCAP", f"{v.get('sgx_sdk') or '–'}; DCAP {v.get('libsgx-dcap-ql') or '–'}"),
        ("Language runtime", v.get("go", "–").replace("go version ", "")),
        ("Deployment", f"single host, one process (enclave) per replica, loopback network, GOMAXPROCS={p.get('worker_gomaxprocs')} per replica"),
    ]
    write_md(os.path.join(out, "table1_platform.md"), ["Parameter", "Value"], rows)
    write_tex(os.path.join(out, "table1_platform.tex"), ["Parameter", "Value"], rows,
              "Experimental platform.", "tab:platform", "lp{0.7\\linewidth}")
    print("Table 1 ->", os.path.join(out, "table1_platform.md"))


# ---------------------------------------------------------------- TEE operations

# (row label, [(runtime, op name)]): the headline rows of the TEE operation table.
HEADLINE = [
    ("Enclave entry + exit: empty ECALL", [("sgx-sdk-hw", "ecall_empty")]),
    ("Enclave exit + entry: empty OCALL", [("sgx-sdk-hw", "ocall_empty")]),
    ("ECALL with 4 KiB copied in", [("sgx-sdk-hw", "ecall_in_4096B")]),
    ("OCALL with 4 KiB copied out", [("sgx-sdk-hw", "ocall_in_4096B")]),
    ("Raw syscall: getppid", [("native", "syscall_getppid"), ("gramine-sgx", "syscall_getppid"), ("ego-sgx", "syscall_getppid")]),
    ("Raw syscall: sched_yield", [("native", "syscall_sched_yield"), ("gramine-sgx", "syscall_sched_yield"), ("ego-sgx", "syscall_sched_yield")]),
    ("Host syscall: UDP send, 64 B", [("native", "udp_send_64B"), ("gramine-sgx", "udp_send_64B"), ("ego-sgx", "udp_send_64B")]),
    ("TCP loopback round trip, 64 B", [("native", "tcp_rtt_64B"), ("gramine-sgx", "tcp_rtt_64B"), ("ego-sgx", "tcp_rtt_64B")]),
    ("ECDSA P-256 sign", [("native", "ecdsa_p256_sign"), ("gramine-sgx", "ecdsa_p256_sign"), ("ego-sgx", "ecdsa_p256_sign")]),
    ("ECDSA P-256 verify", [("native", "ecdsa_p256_verify"), ("gramine-sgx", "ecdsa_p256_verify"), ("ego-sgx", "ecdsa_p256_verify")]),
    ("Report generation: sgx_create_report", [("sgx-sdk-hw", "report_create"), ("sgx-sdk-hw", "report_create_ecall"), ("gramine-sgx", "report"), ("ego-sgx", "report")]),
    ("Report verification: sgx_verify_report", [("sgx-sdk-hw", "report_verify"), ("ego-sgx", "report_verify")]),
    ("Quote generation (DCAP)", [("sgx-sdk-hw", "quote_generate"), ("gramine-sgx", "quote"), ("ego-sgx", "quote")]),
    ("Quote verification (DCAP QVL)", [("sgx-sdk-hw", "quote_verify_collateral"), ("sgx-sdk-hw", "quote_verify"),
                                       ("sgx-sdk-hw", "quote_verify_first"), ("gramine-sgx", "qvl_quote_verify_collateral"),
                                       ("ego-sgx", "qvl_quote_verify_collateral"), ("ego-sgx", "quote_verify")]),
]


def load_teeops(res):
    """Returns {(runtime, op): result} from all microbenchmark outputs."""
    ops = {}
    for path in sorted(glob.glob(os.path.join(res, "teeops", "*.json"))):
        if os.path.basename(path) == "startup.json":
            continue
        doc = load_json(path)
        if not doc:
            continue
        runtime = doc.get("runtime", "?")
        for r in doc.get("results", []):
            name = r["name"]
            rt = runtime
            if runtime == "sgx-sdk-verify":
                # verify-<label>.json: "<label>_<op>", label = runtime that produced the quote;
                # stored as (<label>, "qvl_<op>") to keep it apart from in-enclave verification.
                label, _, rest = name.partition("_")
                rt, name = label, "qvl_" + rest
            ops[(rt, name)] = r
    startup = load_json(os.path.join(res, "teeops", "startup.json")) or []
    by_rt = {}
    for s in startup:
        if s.get("exit_code") == 0:
            by_rt.setdefault(s["runtime"], []).append(s["ns"])
    for rt, v in by_rt.items():
        ops[(rt, "startup")] = {"name": "startup", "batch": 1, "stats": {
            "n": len(v), "mean": statistics.mean(v), "p50": statistics.median(v),
            "p95": max(v), "p99": max(v), "stdev": statistics.stdev(v) if len(v) > 1 else 0}}
    return ops


def table_teeops(res, out):
    ops = load_teeops(res)
    if not ops:
        print("no microbenchmark results, skipping the TEE operation table")
        return
    sdk = "sgx-sdk-hw" if any(k[0] == "sgx-sdk-hw" for k in ops) else "sgx-sdk-sim"
    # full table: every (runtime, op)
    header = ["runtime", "operation", "batch", "n", "mean_us", "stdev_us", "p50_us", "p95_us", "p99_us", "error", "description"]
    rows = []
    for (rt, name), r in sorted(ops.items(), key=lambda kv: (kv[0][1], kv[0][0])):
        s = r.get("stats") or {}
        rows.append([rt, name, r.get("batch", 1), s.get("n", 0)] +
                    [f"{us(s[k]):.3f}" if k in s else "" for k in ("mean", "stdev", "p50", "p95", "p99")] +
                    [r.get("error", ""), r.get("desc", "")])
    write_csv(os.path.join(out, "teeops_all.csv"), header, rows)

    # headline table: p50 [p99] in microseconds per runtime
    runtimes = [sdk, "native", "gramine-direct", "gramine-sgx", "ego-sgx", "ego-sim"]
    runtimes = [rt for rt in runtimes if any(k[0] == rt for k in ops)]
    head = ["Operation", "Variant"] + [RUNTIME_LABELS.get(rt, rt) for rt in runtimes]
    md_rows, tex_rows, csv_rows = [], [], []
    headline = HEADLINE + [("Enclave start-up (process start to exit)", [(rt, "startup") for rt in runtimes])]
    for label, cells in headline:
        variants = {}
        for rt, name in cells:
            rt = sdk if rt == "sgx-sdk-hw" else rt
            variants.setdefault(name, {})[rt] = ops.get((rt, name))
            if rt in ("native", "gramine-sgx", "ego-sgx"):
                for extra in ("gramine-direct", "ego-sim"):
                    if (extra, name) in ops:
                        variants[name][extra] = ops[(extra, name)]
        for name, per_rt in variants.items():
            if not any(per_rt.values()):
                continue
            cols = []
            for rt in runtimes:
                r = per_rt.get(rt)
                s = (r or {}).get("stats")
                if r and r.get("error"):
                    cols.append("error")
                elif s:
                    cols.append(f"{fmt(us(s['p50']))} [{fmt(us(s['p99']))}]")
                    csv_rows.append([label, name, rt, f"{us(s['p50']):.3f}", f"{us(s['p99']):.3f}", f"{us(s['mean']):.3f}"])
                else:
                    cols.append("–")
            md_rows.append([label, name] + cols)
            tex_rows.append([label, name.replace("_", " ")] + cols)
    write_md(os.path.join(out, "teeops.md"), head, md_rows)
    write_csv(os.path.join(out, "teeops.csv"), ["operation", "variant", "runtime", "p50_us", "p99_us", "mean_us"], csv_rows)
    write_tex(os.path.join(out, "teeops.tex"), head, tex_rows,
              "Cost of TEE operations on the SGX server, median [p99] in microseconds.", "tab:teeops",
              "ll" + "r" * len(runtimes))
    print("TEE operations ->", os.path.join(out, "teeops.md"))
    plot_teeops(ops, sdk, out)


def plot_teeops(ops, sdk, out):
    plt = get_plt()
    if not plt:
        return
    names = [("ecall_empty", sdk), ("ocall_empty", sdk), ("report_create", sdk), ("report_verify", sdk),
             ("quote_generate", sdk), ("quote_verify_collateral", sdk), ("quote_verify", sdk)]
    names = [(n, rt) for n, rt in names if (rt, n) in ops and ops[(rt, n)].get("stats")]
    if not names:
        return
    fig, ax = plt.subplots(figsize=(6.5, 0.45 * len(names) + 1))
    p50 = [us(ops[(rt, n)]["stats"]["p50"]) for n, rt in names]
    p99 = [us(ops[(rt, n)]["stats"]["p99"]) for n, rt in names]
    y = range(len(names))
    ax.barh(y, p50, color="#4C72B0", label="median")
    ax.errorbar(p50, y, xerr=[[0] * len(p50), [b - a for a, b in zip(p50, p99)]], fmt="none", ecolor="black", capsize=3, label="p99")
    ax.set_yticks(list(y))
    ax.set_yticklabels([n.replace("_", " ") for n, _ in names])
    ax.set_xscale("log")
    ax.set_xlabel("time per operation (µs, log scale)")
    for yi, v, hi in zip(y, p50, p99):
        ax.annotate(f"{fmt(v)} µs", (hi, yi), xytext=(6, 0), textcoords="offset points", va="center", fontsize=7)
    ax.invert_yaxis()
    ax.legend(loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=2, frameon=False)
    ax.grid(axis="x", which="both", alpha=0.3)
    fig.tight_layout()
    save(fig, out, "teeops")


# ---------------------------------------------------------------- Experiment 1


def load_exp1(res):
    """Returns {(timeout, runtime, protocol, n): [run summaries]}."""
    data = {}
    for meta_path in glob.glob(os.path.join(res, "exp1_tee", "timeout_*", "*", "*", "N*", "run*", "meta.json")):
        run_dir = os.path.dirname(meta_path)
        if not os.path.exists(os.path.join(run_dir, "done")):
            continue
        meta = load_json(meta_path) or {}
        summary = summarize_run(run_dir)  # recomputed: includes the liveness fields
        if not summary:
            continue
        timeout = run_dir.split(os.sep)[-5].removeprefix("timeout_")
        key = (timeout, meta["runtime"], meta["protocol"], int(meta["n"]))
        data.setdefault(key, []).append(summary)
    return data


def agg(values):
    values = [v for v in values if v is not None]
    if not values:
        return None, None
    return statistics.mean(values), statistics.stdev(values) if len(values) > 1 else 0.0


def table_exp1(res, out):
    data = load_exp1(res)
    if not data:
        print("no experiment 1 results, skipping")
        return
    rows = []
    means = {}
    for key in sorted(data, key=lambda k: (k[0], k[2], k[3], RUNTIME_ORDER.index(k[1]) if k[1] in RUNTIME_ORDER else 99)):
        runs = data[key]
        cl, cl_sd = agg([r["client_latency_ms"] for r in runs])
        co, co_sd = agg([r["consensus_latency_ms"] for r in runs])
        th, th_sd = agg([r["throughput_bps"] for r in runs])
        stalled = sum(1 for r in runs if r.get("stalled"))
        means[key] = {"client": cl, "consensus": co, "throughput": th,
                      "client_sd": cl_sd, "consensus_sd": co_sd, "throughput_sd": th_sd,
                      # consensus stopped for good in most runs: not a steady-state measurement
                      "stalled": stalled * 2 > len(runs)}
        rows.append(list(key) + [len(runs), stalled] +
                    [None if v is None else round(v, 4) for v in (cl, cl_sd, co, co_sd, th, th_sd)])
    header = ["view_timeout", "runtime", "protocol", "N", "runs", "stalled_runs", "client_latency_ms", "client_latency_sd",
              "consensus_latency_ms", "consensus_latency_sd", "throughput_bps", "throughput_sd"]
    write_csv(os.path.join(out, "exp1_tee.csv"), header, rows)
    write_md(os.path.join(out, "exp1_tee.md"), header, [[fmt(c) if isinstance(c, float) else c for c in r] for r in rows])
    print("Experiment 1 ->", os.path.join(out, "exp1_tee.md"))

    # Overhead of each TEE runtime over native processes (same process layout), on the
    # paper's metrics: finalization latency (proposal to commit, averaged over all
    # replicas and blocks; with round-robin leaders constant clock offsets between
    # replicas cancel in this mean) and throughput. The client latency is not used
    # here: with the paper's saturating load it measures queueing up to the client timeout.
    head = ["timeout", "protocol", "N", "native ms", "native blocks/s"]
    tee_rts = [rt for rt in TEE_RUNTIMES if any(k[1] == rt for k in means)]
    for rt in tee_rts:
        head += [f"{rt} ms", f"{rt} latency +%", f"{rt} throughput ratio"]
    orows = []
    for (timeout, protocol, n) in sorted({(k[0], k[2], k[3]) for k in means}):
        base = means.get((timeout, "native", protocol, n))
        if not base or not base["consensus"]:
            continue
        row = [timeout, PROTOCOL_LABELS.get(protocol, protocol), n, fmt(base["consensus"]), fmt(base["throughput"])]
        for rt in tee_rts:
            m = means.get((timeout, rt, protocol, n))
            if m and m.get("stalled"):
                row += ["stalled", "–", "–"]
            elif m and m["consensus"]:
                ratio = m["throughput"] / base["throughput"] if m["throughput"] and base["throughput"] else None
                row += [fmt(m["consensus"]), fmt(100 * (m["consensus"] / base["consensus"] - 1), 1), fmt(ratio)]
            else:
                row += ["–", "–", "–"]
        orows.append(row)
    if orows:
        write_md(os.path.join(out, "exp1_overhead.md"), head, orows)
        write_csv(os.path.join(out, "exp1_overhead.csv"), head, orows)
        write_tex(os.path.join(out, "exp1_overhead.tex"), head, orows,
                  "Cost of trusted execution: block finalization latency and throughput with one SGX enclave "
                  "per replica, relative to one native process per replica on the same server.", "tab:sgx-overhead",
                  "llr" + "r" * (len(head) - 3))
        print("Overhead ->", os.path.join(out, "exp1_overhead.md"))
    plot_exp1(means, out)
    plot_tee_vs_bft(means, out)


def plot_series(ax, means, timeout, rt, protocol, metric, label, color, ls):
    """Plots one line; points where consensus stalled are drawn as crosses, off the line."""
    pts = sorted((k[3], v[metric], v.get(metric + "_sd") or 0, v.get("stalled")) for k, v in means.items()
                 if k[0] == timeout and k[1] == rt and k[2] == protocol and v[metric] is not None)
    ok = [p for p in pts if not p[3]]
    bad = [p for p in pts if p[3]]
    if ok:
        ax.errorbar([p[0] for p in ok], [p[1] for p in ok], yerr=[p[2] for p in ok], marker="o", ms=3,
                    color=color, ls=ls, capsize=2, label=label)
    if bad:
        ax.plot([p[0] for p in bad], [p[1] for p in bad], ls="none", marker="X", ms=8, color=color,
                markeredgecolor="black", markeredgewidth=0.5)
        ax.annotate("consensus\nstalls", (bad[0][0], bad[0][1]), xytext=(-8, 0), textcoords="offset points",
                    ha="right", va="center", fontsize=7, color=color)


def plot_exp1(means, out):
    plt = get_plt()
    if not plt:
        return
    timeouts = sorted({k[0] for k in means})
    protocols = [p for p in ("oft", "fasthotstuff") if any(k[2] == p for k in means)]
    runtimes = [rt for rt in RUNTIME_ORDER if any(k[1] == rt for k in means)]
    styles = {"inproc": ("#999999", ":"), "native": ("#000000", "-"), "gramine-direct": ("#8172B2", "--"),
              "gramine-sgx": ("#C44E52", "-"), "gramine-exitless": ("#DD8452", "-."), "ego-sgx": ("#4C72B0", "-"),
              "ego-sim": ("#55A868", "--")}
    for timeout in timeouts:
        for metric, ylabel, fname in (("client", "client latency (ms)", "exp1_tee_client_latency"),
                                      ("consensus", "finalization latency (ms)", "exp1_tee_finalization"),
                                      ("throughput", "throughput (blocks/s)", "exp1_tee_throughput")):
            fig, axes = plt.subplots(1, len(protocols), figsize=(5 * len(protocols), 3.6), squeeze=False)
            for ax, protocol in zip(axes[0], protocols):
                for rt in runtimes:
                    color, ls = styles.get(rt, (None, "-"))
                    plot_series(ax, means, timeout, rt, protocol, metric, RUNTIME_LABELS.get(rt, rt), color, ls)
                ax.set_title(PROTOCOL_LABELS.get(protocol, protocol))
                ax.set_xlabel("replicas (N)")
                ax.set_ylabel(ylabel)
                if metric != "throughput":
                    # the runtimes span two orders of magnitude
                    ax.set_yscale("log")
                ax.grid(alpha=0.3)
            axes[0][-1].legend(fontsize=7)
            fig.tight_layout()
            save(fig, out, f"{fname}_timeout_{timeout}")


def plot_tee_vs_bft(means, out):
    """The paper's main comparison: OFT inside SGX vs. Fast-HotStuff (BFT) without a TEE."""
    plt = get_plt()
    if not plt:
        return
    lines = [
        ("native", "fasthotstuff", "Fast-HotStuff, no TEE (BFT baseline)", "#000000", "--"),
        ("native", "oft", "OFT, no TEE", "#999999", ":"),
        ("ego-sgx", "oft", "OFT in SGX (EGo)", "#4C72B0", "-"),
        ("gramine-sgx", "oft", "OFT in SGX (Gramine)", "#C44E52", "-"),
    ]
    for timeout in sorted({k[0] for k in means}):
        fig, axes = plt.subplots(1, 2, figsize=(10, 3.8))
        for ax, metric, ylabel in ((axes[0], "consensus", "finalization latency (ms)"),
                                   (axes[1], "throughput", "throughput (blocks/s)")):
            for rt, protocol, label, color, ls in lines:
                plot_series(ax, means, timeout, rt, protocol, metric, label, color, ls)
            ax.set_xlabel("replicas (N)")
            ax.set_ylabel(ylabel)
            ax.set_yscale("log")
            ax.grid(alpha=0.3, which="both")
        axes[0].legend(fontsize=7)
        fig.tight_layout()
        save(fig, out, f"exp1_oft_sgx_vs_bft_timeout_{timeout}")


# ---------------------------------------------------------------- helpers


def get_plt():
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        return plt
    except ImportError:
        print("matplotlib not available, skipping figures")
        return None


def save(fig, out, name):
    for ext in ("png", "pdf"):
        fig.savefig(os.path.join(out, f"{name}.{ext}"), dpi=200)
    get_plt().close(fig)


def main():
    res = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "experiments", "results", "tee")
    res = os.path.abspath(res)
    out = os.path.join(res, "analysis")
    os.makedirs(out, exist_ok=True)
    table_platform(res, out)
    table_teeops(res, out)
    table_exp1(res, out)


if __name__ == "__main__":
    main()
