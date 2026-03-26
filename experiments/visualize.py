import json
import matplotlib.pyplot as plt
import numpy as np
import os

# --- Load data ---
RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")

with open(os.path.join(RESULTS_DIR, "exp1", "summary.json")) as f:
    exp1 = json.load(f)

with open(os.path.join(RESULTS_DIR, "exp2", "summary.json")) as f:
    exp2 = json.load(f)

# --- Extract exp1 data ---
oft = exp1["results"]["oft"]
fhs = exp1["results"]["fasthotstuff"]

oft_N = [r["N"] for r in oft]
oft_lat = [r["avg_latency_ms"] for r in oft]
oft_std = [r["std_dev_ms"] for r in oft]

fhs_N = [r["N"] for r in fhs]
fhs_lat = [r["avg_latency_ms"] for r in fhs]
fhs_std = [r["std_dev_ms"] for r in fhs]

# --- Extract exp2 data ---
byz = exp2["results"]
byz_N = [r["N"] for r in byz]
byz_lat = [r["avg_latency_ms"] for r in byz]
byz_std = [r["std_dev_ms"] for r in byz]
byz_f = [r["f_byzantine"] for r in byz]

# --- Style ---
plt.rcParams.update({
    "figure.facecolor": "white",
    "axes.facecolor": "white",
    "axes.grid": True,
    "grid.alpha": 0.3,
    "font.size": 12,
})

# ============================================================
# Figure 1: Experiment 1 — OFT vs FastHotStuff (no attacks)
# ============================================================
fig1, ax1 = plt.subplots(figsize=(12, 6))

ax1.errorbar(oft_N, oft_lat, yerr=oft_std, fmt="o-", color="#2196F3",
             linewidth=2, markersize=6, capsize=4, capthick=1.5,
             label="OFT (1-chain, f+1 quorum)")
ax1.errorbar(fhs_N, fhs_lat, yerr=fhs_std, fmt="s--", color="#FF5722",
             linewidth=2, markersize=6, capsize=4, capthick=1.5,
             label="FastHotStuff (2-chain, 2f+1 quorum)")

ax1.set_xlabel("Number of participants (N)", fontsize=14)
ax1.set_ylabel("Average block finalization time (ms)", fontsize=14)
ax1.set_title("Experiment 1: Block Finalization Time vs N\n(no Byzantine nodes, TEE environment)", fontsize=15)
ax1.set_xticks(oft_N)
ax1.legend(fontsize=12, loc="upper left")

fig1.tight_layout()
fig1.savefig(os.path.join(RESULTS_DIR, "exp1_finalization_time.png"), dpi=150)
print("Saved: exp1_finalization_time.png")

# ============================================================
# Figure 2: Experiment 2 — FastHotStuff with Byzantine nodes
# ============================================================
fig2, ax2 = plt.subplots(figsize=(12, 6))

ax2.errorbar(fhs_N, fhs_lat, yerr=fhs_std, fmt="s--", color="#FF5722",
             linewidth=2, markersize=6, capsize=4, capthick=1.5,
             label="FastHotStuff (no attacks)")
ax2.errorbar(byz_N, byz_lat, yerr=byz_std, fmt="D-", color="#9C27B0",
             linewidth=2, markersize=6, capsize=4, capthick=1.5,
             label="FastHotStuff (f fork-attackers)")

ax2.set_xlabel("Number of participants (N)", fontsize=14)
ax2.set_ylabel("Average block finalization time (ms)", fontsize=14)
ax2.set_title("Experiment 2: Block Finalization Time vs N\n(with f=⌊(N-1)/3⌋ Byzantine nodes, fork attack)", fontsize=15)
ax2.set_xticks(byz_N)
ax2.legend(fontsize=12, loc="upper left")

fig2.tight_layout()
fig2.savefig(os.path.join(RESULTS_DIR, "exp2_byzantine_finalization.png"), dpi=150)
print("Saved: exp2_byzantine_finalization.png")

# ============================================================
# Figure 3: Combined throughput comparison
# ============================================================
fig3, ax3 = plt.subplots(figsize=(12, 6))

oft_thr = [r["avg_throughput_bps"] for r in oft]
fhs_thr = [r["avg_throughput_bps"] for r in fhs]
byz_thr = [r["avg_throughput_bps"] for r in byz]

ax3.plot(oft_N, oft_thr, "o-", color="#2196F3", linewidth=2, markersize=6,
         label="OFT (no attacks)")
ax3.plot(fhs_N, fhs_thr, "s--", color="#FF5722", linewidth=2, markersize=6,
         label="FastHotStuff (no attacks)")
ax3.plot(byz_N, byz_thr, "D-.", color="#9C27B0", linewidth=2, markersize=6,
         label="FastHotStuff (f fork-attackers)")

ax3.set_xlabel("Number of participants (N)", fontsize=14)
ax3.set_ylabel("Average throughput (blocks/sec)", fontsize=14)
ax3.set_title("Throughput Comparison", fontsize=15)
ax3.set_xticks(oft_N)
ax3.legend(fontsize=12)

fig3.tight_layout()
fig3.savefig(os.path.join(RESULTS_DIR, "throughput_comparison.png"), dpi=150)
print("Saved: throughput_comparison.png")

plt.show()
print("\nDone!")
