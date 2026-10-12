#!/usr/bin/env python3
"""Figures and tables for the Part 1 report (E1 performance, E4 correctness).

Reads the newest E1 and E4 file per architecture from results/raw and writes
report/part1/fig/*.pdf and report/part1/tab/*.tex. Every number in the report
comes from here.

  python3 analysis/part1_figures.py
"""
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap, LogNorm  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "results" / "raw"
OUT = ROOT / "report" / "part1"
FIG, TAB = OUT / "fig", OUT / "tab"

# ---------------------------------------------------------------- style
# Colours (validated for colour-vision deficiency, see report appendix):
# machines are always blue (M4) / orange (i7); builds and families use other slots.
M4C, I7C = "#2a78d6", "#eb6834"
REFC, OPTC, OSSLC = "#1baf7a", "#6250d6", "#e87ba4"
FAM = {"ML-KEM": "#1baf7a", "HQC": "#eda100", "FrodoKEM": "#e87ba4", "McEliece": "#008300"}
INK, INK2, MUTED, GRID, AXIS = "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
GOOD = "#0ca30c"
SEQ = LinearSegmentedColormap.from_list("seq", ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
W = 6.3  # text width, inches

plt.rcParams.update({
    "font.family": ["Liberation Sans", "DejaVu Sans"], "font.size": 8.5, "axes.titlesize": 9, "axes.labelsize": 8.5,
    "xtick.labelsize": 7.5, "ytick.labelsize": 7.5, "legend.fontsize": 7.5,
    "axes.edgecolor": AXIS, "axes.linewidth": 0.6, "axes.labelcolor": INK2, "text.color": INK,
    "xtick.color": INK2, "ytick.color": INK2, "xtick.major.width": 0.5, "ytick.major.width": 0.5,
    "xtick.major.size": 2.5, "ytick.major.size": 0, "grid.color": GRID, "grid.linewidth": 0.6,
    "axes.spines.top": False, "axes.spines.right": False, "legend.frameon": False,
    "pdf.fonttype": 42, "savefig.bbox": "tight", "savefig.pad_inches": 0.03,
})

MACH = {"aarch64": ("Apple M4", M4C), "x86_64": ("Intel i7-1185G7", I7C)}
FAMILY_ORDER = ["ML-KEM", "HQC", "FrodoKEM", "McEliece"]
KEMS = ["ML-KEM-512", "ML-KEM-768", "ML-KEM-1024", "HQC-1", "HQC-3", "HQC-5",
        "FrodoKEM-640-SHAKE", "FrodoKEM-976-SHAKE", "FrodoKEM-1344-SHAKE",
        "Classic-McEliece-348864", "Classic-McEliece-460896", "Classic-McEliece-6688128"]
LEVEL = {k: l for k, l in zip(KEMS, [1, 3, 5] * 4)}
BASE = ["X25519-ECDH", "X25519MLKEM768"]
OPS = ["keygen", "encaps", "decaps"]


def short(a):
    return (a.replace("Classic-McEliece-", "McEliece-").replace("FrodoKEM-", "Frodo-").replace("-SHAKE", "")
            .replace("X25519MLKEM768", "X25519+ML-KEM-768").replace("X25519-ECDH", "X25519 (ECDH)")
            .replace("X25519-DHKEM", "X25519 (DHKEM)"))


def family(a):
    for f in FAMILY_ORDER:
        if f in a:
            return f
    return "classical"


def newest(exp, arch):
    files = sorted(RAW.glob(f"{exp}_{arch}_*.csv"))
    files = [f for f in files if not f.name.endswith("_quick.csv")]
    if not files:
        raise SystemExit(f"no {exp} results for {arch}")
    return files[-1]


def meta(path):
    m = {}
    for line in path.read_text().splitlines():
        if line.startswith("# ") and "=" in line:
            k, v = line[2:].split("=", 1)
            m[k.strip()] = v.strip()
    return m


def save(fig, name):
    FIG.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG / f"{name}.pdf")
    plt.close(fig)


def fmt_us(us):
    if us >= 1e6:
        return f"{us / 1e6:.2f} s"
    if us >= 1e3:
        return f"{us / 1e3:.3g} ms" if us < 1e5 else f"{us / 1e3:.0f} ms"
    return f"{us:.3g} µs" if us < 100 else f"{us:.0f} µs"


def log_us_axis(ax, axis="x"):
    """Log axis labelled in ns/µs/ms/s."""
    def f(v, _):
        return fmt_us(v) if v > 0 else ""
    from matplotlib.ticker import FuncFormatter, LogLocator
    a = ax.xaxis if axis == "x" else ax.yaxis
    a.set_major_locator(LogLocator(base=10))
    a.set_major_formatter(FuncFormatter(f))
    a.set_minor_formatter(FuncFormatter(lambda v, _: ""))


# ---------------------------------------------------------------- data
def load():
    e1, e4, md = {}, {}, {}
    for arch in MACH:
        p = newest("e1", arch)
        d = pd.read_csv(p, comment="#")
        d["alg"] = d["alg"].replace({"X25519": "X25519-DHKEM"})
        d["us"] = d.median_ns / 1000
        d["p25_us"], d["p75_us"] = d.p25_ns / 1000, d.p75_ns / 1000
        d["ghz"] = (d.ghz_before + d.ghz_after) / 2
        d["arch"] = arch
        e1[arch] = d
        md[arch] = meta(p) | {"file": p.name}
        q = newest("e4", arch)
        e4[arch] = pd.read_csv(q, comment="#")
        md[arch]["e4file"] = q.name
    return e1, e4, md


def best(d):
    """liboqs opt for the PQ KEMs, OpenSSL for the classical and hybrid baselines."""
    return pd.concat([d[(d.tier == "opt") & d.alg.isin(KEMS)],
                      d[(d.tier == "openssl") & d.alg.isin(BASE + ["X25519-DHKEM"])]])


def full_exchange(d):
    p = best(d).pivot_table(index="alg", columns="op", values="us")
    return p.keygen + p.encaps + p.decaps


# ---------------------------------------------------------------- figures
def fig_sizes(e1):
    d = e1["aarch64"]
    s = d[(d.op == "keygen") & (((d.tier == "opt") & d.alg.isin(KEMS)) |
                                ((d.tier == "openssl") & d.alg.isin(BASE)))].set_index("alg")
    order = BASE + KEMS
    s = s.loc[order]
    fig, ax = plt.subplots(figsize=(W, 3.4))
    y = np.arange(len(order))
    h = 0.36
    ax.barh(y - h / 2 - 0.02, s.pk_bytes, h, color=REFC, label="public key (client → server)", zorder=3)
    ax.barh(y + h / 2 + 0.02, s.ct_bytes, h, color=OPTC, label="ciphertext (server → client)", zorder=3)
    for yi, (pk, ct) in enumerate(zip(s.pk_bytes, s.ct_bytes)):
        ax.text(max(pk, ct) * 1.25, yi, f"{pk + ct:,} B", va="center", fontsize=6.8, color=INK2)
    ax.axvline(65535, color=MUTED, lw=0.8, zorder=2)
    ax.text(65535 * 1.08, -0.9, "TLS key-share limit\n65,535 B", fontsize=6.5, color=INK2, va="bottom")
    ax.set_xscale("log")
    ax.set_xlim(20, 5e6)
    ax.set_yticks(y, [short(a) for a in order])
    ax.invert_yaxis()
    ax.grid(axis="x", zorder=0)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: (f"{v / 1e6:g} MB" if v >= 1e6 else
                                                              f"{v / 1e3:g} KB" if v >= 1e3 else f"{v:g} B")))
    ax.set_xlabel("bytes (log scale)   ·   label = total bytes on the wire")
    ax.legend(loc="upper right", bbox_to_anchor=(1.0, 0.86))
    save(fig, "sizes")


def fig_e4(e4):
    cols = [("kat", "ref"), ("kat", "opt"), ("selftest", "ref"), ("selftest", "opt"),
            ("acvp", "ref"), ("acvp", "opt"), ("cross", "ref<->opt"), ("openssl", "opt")]
    labels = ["KAT\nref", "KAT\nopt", "round trips\nref", "round trips\nopt", "NIST ACVP\nref",
              "NIST ACVP\nopt", "cross-build\nref↔opt", "OpenSSL\ninterop"]
    fig, ax = plt.subplots(figsize=(W, 3.6))
    idx = {a: e4[a].set_index(["check", "tier", "alg"]) for a in MACH}
    for i, a in enumerate(KEMS):
        for j, c in enumerate(cols):
            key = (c[0], c[1], a)
            if key not in idx["aarch64"].index:
                ax.text(j + 0.5, i + 0.5, "–", ha="center", va="center", fontsize=7, color=MUTED)
                continue
            rs = [idx[m].loc[key] for m in MACH]
            ok = all(r.status == "PASS" for r in rs)
            ax.add_patch(plt.Rectangle((j + 0.04, i + 0.08), 0.92, 0.84, color=GOOD if ok else "#d03b3b",
                                       alpha=0.16, lw=0))
            txt = "  ".join(("✓" if r.status == "PASS" else "✗") + f" {int(r.passed)}" for r in rs)
            ax.text(j + 0.5, i + 0.5, txt, ha="center", va="center", fontsize=6.4,
                    color="#006300" if ok else "#d03b3b")
    ax.set_xlim(0, len(cols))
    ax.set_ylim(len(KEMS), 0)
    ax.set_xticks(np.arange(len(cols)) + 0.5, labels, fontsize=6.6)
    ax.set_yticks(np.arange(len(KEMS)) + 0.5, [short(a) for a in KEMS])
    ax.tick_params(length=0)
    ax.xaxis.tick_top()
    for s_ in ax.spines.values():
        s_.set_visible(False)
    n = {m: (len(e4[m]), int(e4[m].passed.sum()), int((e4[m].status == "PASS").sum())) for m in MACH}
    fig.text(0.5, -0.06, "each cell: M4 result, then i7 result (✓ n = n vectors or round trips passed); "
             "– = not applicable\n"
             f"M4 {n['aarch64'][2]}/{n['aarch64'][0]} checks, {n['aarch64'][1]:,} vectors · "
             f"i7 {n['x86_64'][2]}/{n['x86_64'][0]} checks, {n['x86_64'][1]:,} vectors",
             ha="center", fontsize=6.6, color=INK2)
    save(fig, "e4_matrix")


def fig_full_exchange(e1):
    order = BASE + KEMS
    fx = {a: full_exchange(e1[a]) for a in MACH}
    fig, ax = plt.subplots(figsize=(W, 3.9))
    y = np.arange(len(order))
    h = 0.36
    for k, (arch, off) in enumerate(zip(MACH, (-h / 2 - 0.02, h / 2 + 0.02))):
        v = fx[arch].loc[order]
        ax.barh(y + off, v, h, color=MACH[arch][1], label=MACH[arch][0], zorder=3)
    for yi, a in enumerate(order):
        m4, i7 = fx["aarch64"][a], fx["x86_64"][a]
        ax.text(max(m4, i7) * 1.25, yi, f"{fmt_us(m4)} / {fmt_us(i7)}", va="center", fontsize=6.6, color=INK2)
    for arch in MACH:
        ax.axvline(fx[arch]["X25519-ECDH"], color=MACH[arch][1], lw=0.7, alpha=0.6, zorder=2)
    ax.set_xscale("log")
    log_us_axis(ax)
    ax.set_xlim(5, 2e6)
    ax.set_yticks(y, [short(a) for a in order])
    ax.invert_yaxis()
    ax.grid(axis="x", zorder=0)
    ax.set_xlabel("keygen + encaps + decaps (median per call, summed), log scale   ·   label = M4 / i7")
    ax.legend(loc="upper right")
    save(fig, "full_exchange")


def fig_relative(e1):
    order = [a for a in BASE + KEMS if a != "X25519-ECDH"]
    fig, ax = plt.subplots(figsize=(W, 3.5))
    y = np.arange(len(order))
    for arch, off, mk in (("aarch64", -0.14, "o"), ("x86_64", 0.14, "D")):
        fx = full_exchange(e1[arch])
        r = fx.loc[order] / fx["X25519-ECDH"]
        ax.scatter(r, y + off, s=26, color=MACH[arch][1], marker=mk, zorder=3, label=MACH[arch][0],
                   edgecolor="white", linewidth=0.8)
    rel = {a: full_exchange(e1[a]) for a in MACH}
    for yi, a in enumerate(order):
        m, i = (rel[k][a] / rel[k]["X25519-ECDH"] for k in ("aarch64", "x86_64"))
        g = lambda v: f"{v:,.0f}×" if v >= 100 else f"{v:.2g}×"
        if m < 1:
            ax.text(1.15, yi, f"{1 / m:.1f}× / {1 / i:.1f}× cheaper", va="center", ha="left",
                    fontsize=6.3, color=INK2)
        else:
            ax.text(max(m, i) * 1.35, yi, f"{g(m)} / {g(i)}", va="center", ha="left", fontsize=6.3,
                    color=INK2)
    ax.axvline(1, color=INK2, lw=0.9, zorder=2)
    ax.text(1.06, -0.95, "X25519 ECDH = 1×   ·   labels: M4 / i7", fontsize=6.8, color=INK2)
    ax.axvspan(0.02, 1, color="#f0efec", zorder=0)
    ax.text(0.03, len(order) - 0.4, "cheaper than\nclassical DH", fontsize=6.8, color=INK2, va="bottom")
    ax.set_xscale("log")
    ax.set_xlim(0.03, 3e4)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}×"))
    ax.set_yticks(y, [short(a) for a in order])
    ax.invert_yaxis()
    ax.grid(axis="x", zorder=0)
    ax.set_xlabel("full-exchange cost relative to X25519 ECDH on the same machine (log scale)")
    ax.legend(loc="upper right")
    save(fig, "relative_to_x25519")


def fig_per_op(e1):
    order = BASE + KEMS
    fig, axes = plt.subplots(1, 3, figsize=(W, 3.9), sharey=True)
    y = np.arange(len(order))
    h = 0.36
    for ax, op in zip(axes, OPS):
        for arch, off in zip(MACH, (-h / 2 - 0.02, h / 2 + 0.02)):
            b = best(e1[arch])
            v = b[b.op == op].set_index("alg").loc[order]
            ax.barh(y + off, v.us, h, color=MACH[arch][1], label=MACH[arch][0], zorder=3)
            ax.errorbar(v.us, y + off, xerr=[v.us - v.p25_us, v.p75_us - v.us], fmt="none",
                        ecolor=INK2, elinewidth=0.6, capsize=0, zorder=4)
        ax.set_xscale("log")
        log_us_axis(ax)
        ax.set_xlim(2, 1e6)
        ax.set_title(op, color=INK)
        ax.grid(axis="x", zorder=0)
    axes[0].set_yticks(y, [short(a) for a in order])
    axes[0].invert_yaxis()
    h_, l_ = axes[0].get_legend_handles_labels()
    fig.legend(h_, l_, loc="upper center", ncol=2, bbox_to_anchor=(0.55, 1.04))
    fig.supxlabel("median per call (log scale); whiskers = interquartile range", fontsize=8, color=INK2, y=0.02)
    fig.tight_layout(w_pad=0.6)
    save(fig, "per_op")


def fig_tradeoff(e1):
    d = e1["aarch64"]
    sz = d[(d.op == "keygen")].drop_duplicates("alg").set_index("alg")
    order = BASE + KEMS
    fig, ax = plt.subplots(figsize=(W, 3.8))
    for arch, mk in (("aarch64", "o"), ("x86_64", "D")):
        fx = full_exchange(e1[arch])
        xs = [sz.loc[a].pk_bytes + sz.loc[a].ct_bytes for a in order]
        ys = [fx[a] for a in order]
        ax.scatter(xs, ys, s=30, marker=mk, color=MACH[arch][1], edgecolor="white", linewidth=0.8,
                   zorder=3, label=MACH[arch][0])
    fx = full_exchange(e1["aarch64"])
    offs = {"X25519-ECDH": (8, -3), "X25519MLKEM768": (8, 6), "ML-KEM-512": (-6, -12), "ML-KEM-768": (8, -10),
            "ML-KEM-1024": (8, 2)}
    for a in order:
        x = sz.loc[a].pk_bytes + sz.loc[a].ct_bytes
        dx, dy = offs.get(a, (7, -3))
        ax.annotate(short(a), (x, fx[a]), xytext=(dx, dy), textcoords="offset points", fontsize=6.6,
                    color=INK2, ha="left" if dx > 0 else "right")
    ax.axvline(65535, color=MUTED, lw=0.8)
    ax.text(65535 * 1.1, 8, "TLS key-share limit", fontsize=6.6, color=INK2)
    ax.set_xscale("log")
    ax.set_yscale("log")
    log_us_axis(ax, "y")
    ax.set_xlim(30, 4e6)
    ax.set_ylim(6, 1e6)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: (f"{v / 1e6:g} MB" if v >= 1e6 else
                                                              f"{v / 1e3:g} KB" if v >= 1e3 else f"{v:g} B")))
    ax.grid(zorder=0)
    ax.set_xlabel("bytes on the wire per exchange (public key + ciphertext), log scale")
    ax.set_ylabel("full-exchange compute, log scale")
    ax.legend(loc="upper left")
    ax.text(40, 9, "ideal corner:\nsmall and fast", fontsize=6.8, color=MUTED)
    save(fig, "tradeoff")


def fig_levels(e1):
    fig, axes = plt.subplots(1, 2, figsize=(W, 2.9), sharey=True)
    markers = {"ML-KEM": "o", "HQC": "s", "FrodoKEM": "^", "McEliece": "D"}
    for ax, arch in zip(axes, MACH):
        fx = full_exchange(e1[arch])
        for f in FAMILY_ORDER:
            ks = [k for k in KEMS if family(k) == f]
            ax.plot([1, 3, 5], [fx[k] for k in ks], color=FAM[f], lw=2, marker=markers[f], ms=5,
                    markeredgecolor="white", markeredgewidth=0.8, solid_capstyle="round")
            ax.text(5.25, fx[ks[-1]], f, fontsize=7, color=INK2, va="center")
        ax.axhline(fx["X25519-ECDH"], color=MUTED, lw=0.8)
        ax.text(1.0, fx["X25519-ECDH"] * 1.35, "X25519 ECDH", fontsize=6.6, color=INK2)
        ax.set_yscale("log")
        log_us_axis(ax, "y")
        ax.set_xticks([1, 3, 5], ["Level 1", "Level 3", "Level 5"])
        ax.set_xlim(0.7, 6.4)
        ax.set_title(MACH[arch][0], color=INK)
        ax.grid(axis="y", zorder=0)
    axes[0].set_ylabel("full-exchange compute (log)")
    fig.tight_layout(w_pad=1.0)
    save(fig, "levels")


def fig_speedup(e1):
    fig, axes = plt.subplots(1, 2, figsize=(W, 3.4))
    norm = LogNorm(vmin=0.8, vmax=1500)
    for ax, arch in zip(axes, MACH):
        d = e1[arch]
        s = d[d.alg.isin(KEMS)].pivot_table(index="alg", columns=["tier", "op"], values="median_ns")
        sp = pd.DataFrame({op: s[("ref", op)] / s[("opt", op)] for op in OPS}).loc[KEMS]
        ax.imshow(sp.clip(lower=0.8).values, cmap=SEQ, norm=norm, aspect="auto")
        for i in range(len(KEMS)):
            for j in range(3):
                v = sp.values[i, j]
                ax.text(j, i, f"{v:.0f}×" if v >= 10 else f"{v:.1f}×", ha="center", va="center", fontsize=6.6,
                        color="white" if v >= 20 else INK)
        ax.set_xticks(range(3), OPS)
        ax.set_yticks(range(len(KEMS)), [short(a) for a in KEMS] if arch == "aarch64" else [])
        ax.tick_params(length=0)
        ax.xaxis.tick_top()
        for s_ in ax.spines.values():
            s_.set_visible(False)
        isa = "NEON" if arch == "aarch64" else "AVX2"
        ax.set_title(f"{MACH[arch][0]} ({isa})", color=INK, pad=18)
    fig.text(0.5, 0.0, "speed-up = ref time / opt time; darker = larger speed-up (log colour scale); "
             "1.0× = no optimised code for that KEM", ha="center", fontsize=6.8, color=INK2)
    fig.tight_layout(w_pad=1.5)
    save(fig, "speedup")


def fig_machine_ratio(e1):
    fig, ax = plt.subplots(figsize=(W, 3.3))
    order = KEMS
    y = np.arange(len(order))
    for tier, off, col, mk in (("ref", -0.15, REFC, "o"), ("opt", 0.15, OPTC, "D")):
        rs = []
        for a in order:
            fa = e1["aarch64"]; fx = e1["x86_64"]
            pa = fa[(fa.tier == tier) & (fa.alg == a)].us.sum()
            px = fx[(fx.tier == tier) & (fx.alg == a)].us.sum()
            rs.append(px / pa)
        ax.scatter(rs, y + off, s=26, marker=mk, color=col, edgecolor="white", linewidth=0.8, zorder=3,
                   label=f"{tier} build" + (" (portable C)" if tier == "ref" else " (AVX2 / NEON)"))
    ax.axvline(1, color=INK2, lw=0.9)
    ax.text(1.08, -0.95, "same speed", fontsize=6.6, color=INK2)
    ax.text(0.27, len(order) - 0.35, "← i7 faster", fontsize=7, color=INK2)
    ax.text(3.6, len(order) - 0.35, "M4 faster →", fontsize=7, color=INK2, ha="right")
    ax.set_xscale("log")
    ax.set_xlim(0.25, 4)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}×"))
    ax.set_yticks(y, [short(a) for a in order])
    ax.invert_yaxis()
    ax.grid(axis="x", zorder=0)
    ax.set_xlabel("i7 time / M4 time for a full exchange (log scale)")
    ax.legend(loc="upper left")
    save(fig, "machine_ratio")


def fig_clock(e1):
    fig, axes = plt.subplots(1, 2, figsize=(W, 2.6), sharey=True)
    for ax, arch in zip(axes, MACH):
        d = e1[arch]
        rng = np.random.default_rng(1)
        for k, (tier, col) in enumerate((("ref", REFC), ("opt", OPTC), ("openssl", OSSLC))):
            v = d[d.tier == tier].ghz.dropna()
            ax.scatter(k + rng.uniform(-0.18, 0.18, len(v)), v, s=10, color=col, alpha=0.85, lw=0, zorder=3)
            ax.text(k, 4.6, f"median\n{v.median():.2f} GHz", ha="center", va="bottom",
                    fontsize=6.4, color=INK2)
        ax.set_xticks([0, 1, 2], ["ref", "opt", "OpenSSL"])
        ax.set_title(MACH[arch][0], color=INK)
        ax.grid(axis="y", zorder=0)
        ax.set_xlim(-0.6, 2.6)
    axes[0].set_ylabel("estimated core clock (GHz)")
    axes[0].set_ylim(2.8, 4.95)
    fig.tight_layout(w_pad=1.0)
    save(fig, "clock")


def fig_hybrid(e1):
    fig, axes = plt.subplots(1, 2, figsize=(W, 2.3), sharey=True)
    for ax, arch in zip(axes, MACH):
        d = e1[arch]
        g = lambda a, op: float(d[(d.tier == "openssl") & (d.alg == a) & (d.op == op)].us.iloc[0])
        y = np.arange(3)
        ec = [g("X25519-ECDH", op) for op in OPS]
        mk = [g("ML-KEM-768", op) for op in OPS]
        hy = [g("X25519MLKEM768", op) for op in OPS]
        ax.barh(y - 0.2, ec, 0.36, color="#898781", label="X25519 ECDH", zorder=3)
        ax.barh(y - 0.2, mk, 0.36, left=np.array(ec) + max(ec) * 0.01, color=REFC, label="ML-KEM-768 (OpenSSL)",
                zorder=3)
        ax.barh(y + 0.2, hy, 0.36, color=OPTC, label="hybrid, measured", zorder=3)
        for yi in range(3):
            ax.text(hy[yi] + 1, yi + 0.2, f"{hy[yi]:.1f} µs", va="center", fontsize=6.4, color=INK2)
            ax.text(ec[yi] + mk[yi] + 1.5, yi - 0.2, f"{ec[yi] + mk[yi]:.1f} µs", va="center", fontsize=6.4,
                    color=INK2)
        ax.set_yticks(y, OPS)
        ax.set_xlim(0, max(hy + [e + m for e, m in zip(ec, mk)]) * 1.25)
        ax.set_title(MACH[arch][0], color=INK)
        ax.grid(axis="x", zorder=0)
        ax.set_xlabel("µs (median)")
    axes[0].invert_yaxis()
    h_, l_ = axes[0].get_legend_handles_labels()
    fig.legend(h_, l_, loc="upper center", ncol=3, bbox_to_anchor=(0.5, 1.08))
    fig.tight_layout(w_pad=1.0)
    save(fig, "hybrid")


def fig_ecdh_dhkem(e1):
    fig, axes = plt.subplots(1, 2, figsize=(W, 2.0), sharey=True)
    for ax, arch in zip(axes, MACH):
        d = e1[arch]
        y = np.arange(3)
        for alg, off, col in (("X25519-ECDH", -0.19, REFC), ("X25519-DHKEM", 0.19, OPTC)):
            v = d[(d.tier == "openssl") & (d.alg == alg)].set_index("op").loc[OPS]
            ax.barh(y + off, v.us, 0.34, color=col, zorder=3, label=short(alg))
            for yi, u in enumerate(v.us):
                ax.text(u + 0.8, yi + off, f"{u:.1f}", va="center", fontsize=6.3, color=INK2)
        ax.set_yticks(y, OPS)
        ax.set_title(MACH[arch][0], color=INK)
        ax.grid(axis="x", zorder=0)
        ax.set_xlabel("µs (median)")
        ax.set_xlim(0, d[(d.tier == "openssl") & d.alg.str.startswith("X25519-")].us.max() * 1.22)
    axes[0].invert_yaxis()
    h_, l_ = axes[0].get_legend_handles_labels()
    fig.legend(h_, l_, loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.1))
    fig.tight_layout(w_pad=1.0)
    save(fig, "ecdh_vs_dhkem")


def fig_stack(e1):
    d = e1["aarch64"]
    s = d[(d.tier == "opt") & d.alg.isin(KEMS)].pivot_table(index="alg", columns="op", values="stack_bytes")
    s = s.loc[KEMS].max(axis=1)
    fig, ax = plt.subplots(figsize=(W, 2.6))
    y = np.arange(len(KEMS))
    ax.barh(y, s / 1024, 0.5, color=[FAM[family(a)] for a in KEMS], zorder=3)
    for yi, v in enumerate(s / 1024):
        ax.text(v * 1.15, yi, f"{v:,.0f} KiB", va="center", fontsize=6.5, color=INK2)
    ax.axvline(64, color=MUTED, lw=0.8)
    ax.text(64 * 1.08, -0.6, "64 KiB", fontsize=6.5, color=INK2)
    ax.set_xscale("log")
    ax.set_xlim(3, 6000)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:,.0f} KiB"))
    ax.set_yticks(y, [short(a) for a in KEMS])
    ax.invert_yaxis()
    ax.grid(axis="x", zorder=0)
    ax.set_xlabel("peak stack use of the costliest operation, KiB (log scale; liboqs opt, M4)")
    save(fig, "stack")


# ---------------------------------------------------------------- tables
def tex_table(path, header, rows, colspec, caption=None, top=None):
    TAB.mkdir(parents=True, exist_ok=True)
    lines = [r"\begin{tabular}{" + colspec + "}", r"\toprule"] + ([top] if top else []) + \
            [" & ".join(header) + r" \\", r"\midrule"]
    for r in rows:
        lines.append(r"\midrule" if r == "MID" else " & ".join(r) + r" \\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    (TAB / path).write_text("\n".join(lines) + "\n")


def esc(s):
    return s.replace(" µs", r"\,µs").replace(" ms", r"\,ms").replace(" s", r"\,s").replace("_", r"\_")


def tables(e1, e4, md):
    # Full medians per machine and build
    for arch in MACH:
        d = e1[arch]
        rows = []
        for a in BASE + ["X25519-DHKEM"] + KEMS:
            for tier in ("ref", "opt", "openssl"):
                r = d[(d.alg == a) & (d.tier == tier)].set_index("op")
                if r.empty or not all(o in r.index for o in OPS):
                    continue
                cyc = [r.loc[o].median_core_cycles_est for o in OPS]
                rows.append([short(a), tier] + [fmt_us(r.loc[o].us) for o in OPS] +
                            [f"{c / 1e3:,.0f}k" if c < 1e7 else f"{c / 1e6:,.1f}M" for c in cyc] +
                            [f"{max((r.loc[o].p75_us - r.loc[o].p25_us) / r.loc[o].us for o in OPS) * 100:.0f}\\%"])
            if a in ("X25519-DHKEM", "ML-KEM-1024", "HQC-5", "FrodoKEM-1344-SHAKE"):
                rows.append("MID")
        tex_table(f"e1_full_{arch}.tex",
                  ["KEM", "build", "keygen", "encaps", "decaps", "kg cyc", "enc cyc", "dec cyc", "IQR"],
                  [[esc(c) for c in r] if r != "MID" else r for r in rows], "llrrrrrrr")
    # Sizes
    d = e1["aarch64"]
    rows = []
    for a in ["X25519-ECDH"] + KEMS + ["X25519MLKEM768"]:
        r = d[(d.alg == a) & (d.op == "keygen")].iloc[0]
        sk = int(r.sk_bytes) if r.sk_bytes > 0 else 32 if a == "X25519-ECDH" else None
        rows.append([short(a), f"{LEVEL.get(a, '–')}", f"{int(r.pk_bytes):,}",
                     f"{sk:,}" if sk else "–", f"{int(r.ct_bytes):,}", f"{int(r.ss_bytes)}",
                     f"{int(r.pk_bytes + r.ct_bytes):,}"])
    tex_table("sizes.tex", ["KEM", "level", "public key", "secret key", "ciphertext", "shared secret", "on wire"],
              rows, "lrrrrrr")
    # Machines
    rows = []
    for k, lab in (("cpu", "CPU"), ("cores", "cores"), ("virtualisation", "environment"), ("kernel", "kernel"),
                   ("cc", "compiler"), ("liboqs", "liboqs"), ("openssl", "OpenSSL"), ("tick_mhz", "timer (MHz)"),
                   ("core_ghz_at_start", "core clock at start (GHz)"), ("n_ops", "timed calls per op"),
                   ("n_mce_keygen", "McEliece keygens"), ("cooldown_s", "cooldown (s)"), ("warmup_ms", "warm-up (ms)"),
                   ("repo_commit", "code commit")):
        rows.append([lab] + [esc(md[a].get(k, "–")).replace("11th Gen Intel(R) Core(TM) ", "Intel ")
                             .replace("cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0", "GCC 13.3.0 (Ubuntu 24.04)")
                             .replace("wsl in WSL2", "WSL2 (Ubuntu 24.04)")
                             .replace("container in Docker Desktop VM (linuxkit)", "Docker Desktop (Linux VM)")
                             .replace("openssl-", "").replace(" @ 3.00GHz", "")
                             for a in MACH])
    tex_table("machines.tex", ["", "Apple M4 (ARM64)", "Intel i7-1185G7 (x86-64)"], rows, "lll")
    # Published comparison (i7, core cycles)
    x = e1["x86_64"]
    cyc = lambda a, op, tier="opt": float(x[(x.alg == a) & (x.op == op) & (x.tier == tier)].median_core_cycles_est.iloc[0])
    pub = [
        ("ML-KEM-768, AVX2", "ML-KEM-768", "opt", (52732, 67624, 53156), "Kyber R3 spec, Haswell"),
        ("ML-KEM-768, portable", "ML-KEM-768", "ref", (199408, 235260, 274900), "Kyber R3 spec, Haswell"),
        ("HQC-1, portable", "HQC-1", "opt", (4557e3, 9116e3, 13918e3), "HQC spec 2025, i7-11850H"),
        ("Frodo-640, AVX2", "FrodoKEM-640-SHAKE", "opt", (4031e3, 4218e3, 4116e3), "FrodoKEM spec, Skylake"),
        ("McEliece-348864, AVX2", "Classic-McEliece-348864", "opt", (46.5e6, 43832, 134184), "McEliece R3, Haswell"),
    ]
    def k(v):
        return f"{v / 1e6:.1f}M" if v >= 1e6 else f"{v / 1e3:.0f}k"
    rows = []
    for lab, a, tier, p, src in pub:
        ours = [cyc(a, o, tier) for o in OPS]
        rows.append([lab] + [f"{k(o)} / {k(q)}" for o, q in zip(ours, p)] +
                    [f"{np.mean([o / q for o, q in zip(ours, p)]):.2f}", src])
    tex_table("published.tex", ["", "keygen", "encaps", "decaps", "ours/pub.", "published on"], rows, "lrrrrl")
    # Headline numbers as macros
    fx = {a: full_exchange(e1[a]) for a in MACH}
    mac = []
    for arch, tag in (("aarch64", "M"), ("x86_64", "I")):
        f = fx[arch]
        for a, n in (("X25519-ECDH", "ecdh"), ("ML-KEM-512", "mlkemI"), ("ML-KEM-768", "mlkemIII"),
                     ("ML-KEM-1024", "mlkemV"), ("X25519MLKEM768", "hybrid"), ("HQC-1", "hqcI"),
                     ("FrodoKEM-640-SHAKE", "frodoI"), ("Classic-McEliece-348864", "mceI")):
            mac.append(rf"\newcommand{{\fx{tag}{n}}}{{{esc(fmt_us(f[a]))}}}")
            rv = f[a] / f["X25519-ECDH"]
            mac.append(rf"\newcommand{{\rel{tag}{n}}}{{{rv:,.0f}}}" if rv >= 100 else
                       rf"\newcommand{{\rel{tag}{n}}}{{{rv:.2g}}}")
            if rv < 1:
                mac.append(rf"\newcommand{{\inv{tag}{n}}}{{{1 / rv:.1f}}}")
    e4n = {a: int(e4[a].passed.sum()) for a in MACH}
    mac.append(rf"\newcommand{{\eFourVectors}}{{{e4n['aarch64']:,}}}")
    mac.append(rf"\newcommand{{\eFourChecks}}{{{len(e4['aarch64'])}}}")
    (TAB / "numbers.tex").write_text("\n".join(mac) + "\n")


def summary_tables(e1, e4):
    """Compact plain-language tables for the 3-page summary (tab/sum_*.tex)."""
    order = BASE + KEMS
    name = lambda a: {"X25519-ECDH": "X25519 (today)", "X25519MLKEM768": "Hybrid X25519+ML-KEM-768"}.get(a, short(a))
    lvl = lambda a: str(LEVEL.get(a, "–"))
    def t(us):
        for div, unit in ((1e6, "s"), (1e3, "ms"), (1, "µs")):
            if us >= div or unit == "µs":
                v = us / div
                txt = f"{v:.2f}" if v < 10 else f"{v:.1f}" if v < 100 else f"{v:,.0f}"
                return txt + r"\," + unit
    def x(v):
        return (f"{v:.2f}×" if v < 1 else f"{v:.1f}×" if v < 10 else f"{v:.0f}×" if v < 100 else f"{v:,.0f}×")
    fx = {a: full_exchange(e1[a]) for a in MACH}
    d = e1["aarch64"]
    sz = d[d.op == "keygen"].drop_duplicates("alg").set_index("alg")
    # A: whole key exchange
    rows = []
    for a in order:
        if a in ("ML-KEM-512", "HQC-1", "FrodoKEM-640-SHAKE", "Classic-McEliece-348864"):
            rows.append("MID")
        b = int(sz.loc[a].pk_bytes + sz.loc[a].ct_bytes)
        m, i = fx["aarch64"][a], fx["x86_64"][a]
        rows.append([name(a), lvl(a), f"{b:,}", t(m), x(m / fx["aarch64"]["X25519-ECDH"]),
                     t(i), x(i / fx["x86_64"]["X25519-ECDH"])])
    tex_table("sum_full.tex", ["Method", "Level", "Bytes sent", "Time (M4)", "vs X25519", "Time (Intel)", "vs X25519"],
              rows, "lrrrrrr")
    # B: per step
    rows = []
    for a in order:
        if a in ("ML-KEM-512", "HQC-1", "FrodoKEM-640-SHAKE", "Classic-McEliece-348864"):
            rows.append("MID")
        r = [name(a)]
        for arch in MACH:
            bb = best(e1[arch]).set_index(["alg", "op"])
            r += [t(bb.loc[(a, op)].us) for op in OPS]
        rows.append(r)
    tex_table("sum_ops.tex", ["Method", "KeyGen", "Encaps", "Decaps", "KeyGen", "Encaps", "Decaps"], rows, "lrrrrrr",
              top=r" & \multicolumn{3}{c}{\textbf{Apple M4}} & \multicolumn{3}{c}{\textbf{Intel i7}} \\ "
                  r"\cmidrule(lr){2-4}\cmidrule(lr){5-7}")
    # C: optimised code and memory
    rows = []
    for a in KEMS:
        if a in ("HQC-1", "FrodoKEM-640-SHAKE", "Classic-McEliece-348864"):
            rows.append("MID")
        r = [name(a)]
        for arch in ("x86_64", "aarch64"):
            q = e1[arch][e1[arch].alg == a].pivot_table(index="op", columns="tier", values="median_ns")
            r += [(lambda v: f"{v:.1f}×" if v < 10 else f"{v:,.0f}×")(q.loc[op, "ref"] / q.loc[op, "opt"]) for op in OPS]
        st = d[(d.tier == "opt") & (d.alg == a)].stack_bytes.max() / 1024
        r.append(f"{st:,.0f}")
        rows.append(r)
    tex_table("sum_impl.tex", ["Method", "KeyGen", "Encaps", "Decaps", "KeyGen", "Encaps", "Decaps", "(KiB)"],
              rows, "lrrrrrrr",
              top=r" & \multicolumn{3}{c}{\textbf{Intel i7 (AVX2)}} & \multicolumn{3}{c}{\textbf{Apple M4 (NEON)}} & "
                  r"\textbf{Memory} \\ \cmidrule(lr){2-4}\cmidrule(lr){5-7}\cmidrule(lr){8-8}")
    # D: correctness
    checks = [("kat", "Answers match known correct results", "all 12, both versions"),
              ("acvp", "NIST official FIPS 203 test vectors", "ML-KEM"),
              ("selftest", "Random exchanges give the same secret", "all 12, both versions"),
              ("cross", "Keys from one version work with the other", "all 12"),
              ("openssl", "liboqs and OpenSSL work together", "ML-KEM")]
    rows = []
    for c, what, applies in checks:
        r = [what, applies]
        for arch in MACH:
            g = e4[arch][e4[arch].check == c]
            r.append(f"{int((g.status == 'PASS').sum())}/{len(g)} ({int(g.passed.sum()):,} cases)")
        rows.append(r)
    rows.append("MID")
    rows.append([r"\textbf{Total}", ""] + [rf"\textbf{{{int((e4[a].status == 'PASS').sum())}/{len(e4[a])} "
                                         rf"({int(e4[a].passed.sum()):,} cases)}}" for a in MACH])
    tex_table("sum_e4.tex", ["What is checked", "Applies to", "M4: passed", "Intel: passed"], rows, "llll")


def main():
    e1, e4, md = load()
    for f in (fig_sizes, fig_full_exchange, fig_relative, fig_per_op, fig_tradeoff, fig_levels,
              fig_speedup, fig_machine_ratio, fig_clock, fig_hybrid, fig_ecdh_dhkem, fig_stack):
        f(e1)
    fig_e4(e4)
    tables(e1, e4, md)
    summary_tables(e1, e4)
    print("inputs:", ", ".join(md[a]["file"] for a in MACH), ",", ", ".join(md[a]["e4file"] for a in MACH))
    print("wrote", len(list(FIG.glob('*.pdf'))), "figures and", len(list(TAB.glob('*.tex'))), "tables to", OUT)


if __name__ == "__main__":
    main()
