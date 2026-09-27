#!/usr/bin/env python3
"""Turn results/raw/*.csv into report figures (figures/) and LaTeX tables
(report/tables/). Uses the newest full run of each experiment per
architecture; INCLUDE_QUICK=1 also accepts smoke-test (_quick) files.

  E1  fig_e1_ops.pdf       median time per operation, log scale, ref/opt/OpenSSL,
                           one panel per operation (rows = architecture)
      tab_sizes.tex        key / ciphertext sizes and peak stack
      tab_e1_<arch>.tex    median microseconds per operation
  E2  fig_e2_handshake.pdf median handshake time per group, one panel per RTT,
                           bars = packet loss
      tab_e2_bytes.tex     bytes on the wire per group (no delay, no loss)
  E3  fig_e3_dudect.pdf    |t| per target with the 4.5 and 10 thresholds
      tab_e3_valgrind.tex  Valgrind findings vs liboqs' known-issue list
      tab_e3_divscan.tex   DIV instructions in the KyberSlash functions
  E4  tab_e4.tex           checks passed per KEM
"""
import os
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

FIG = pqlib.ROOT / "figures"
TAB = pqlib.ROOT / "report" / "tables"
INCLUDE_QUICK = os.environ.get("INCLUDE_QUICK", "0") == "1"

# Validated palette (dataviz reference instance, light mode): categorical
# slots 1-3 pass all-pairs CVD checks; ordinal ramp = blue 250/450/650.
TIER_COLOR = {"ref": "#2a78d6", "opt": "#eb6834", "openssl": "#1baf7a"}
TIER_LABEL = {"ref": "liboqs portable C (ref)", "opt": "liboqs optimised (opt)",
              "openssl": "OpenSSL 3.5 native"}
LOSS_COLOR = ["#86b6ef", "#2a78d6", "#104281"]
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"

plt.rcParams.update({
    "font.size": 9, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2,
    "ytick.color": INK2, "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "axes.axisbelow": True, "axes.spines.top": False, "axes.spines.right": False,
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "legend.frameon": False, "pdf.fonttype": 42,
})


def latest(exp: str) -> dict[str, pd.DataFrame]:
    """Newest CSV per architecture for one experiment: {arch: DataFrame}."""
    out = {}
    for f in sorted(pqlib.RAW.glob(f"{exp}_*.csv")):
        if f.name.endswith("_quick.csv") and not INCLUDE_QUICK:
            continue
        arch = f.name[len(exp) + 1:].rsplit("_", 1)[0].replace("_quick", "")
        arch = "x86_64" if arch.startswith("x86_64") else arch.split("_")[0]
        out[arch] = f  # sorted by name -> newest wins
    return {a: pd.read_csv(f, comment="#") for a, f in out.items()}


def save(fig, name):
    FIG.mkdir(exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(FIG / f"{name}.{ext}", dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"  figures/{name}.pdf")


def tex_escape(v) -> str:
    s = str(v)
    for a, b in (("\\", r"\textbackslash{}"), ("&", r"\&"), ("%", r"\%"), ("$", r"\$"),
                 ("#", r"\#"), ("_", r"\_"), ("{", r"\{"), ("}", r"\}"), ("~", r"\textasciitilde{}")):
        s = s.replace(a, b)
    return s


def write_tex(name, df, caption, label, fmt=None):
    """Booktabs table without pandas' Styler (which needs a recent jinja2)."""
    fmt = fmt or (lambda x: f"{x:,.1f}")

    def cell(v):
        if v is None or (isinstance(v, float) and pd.isna(v)) or v is pd.NA:
            return "--"
        if isinstance(v, bool):
            return "yes" if v else "no"
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return tex_escape(fmt(v))
        return tex_escape(v)

    num = [pd.api.types.is_numeric_dtype(df[c]) and not pd.api.types.is_bool_dtype(df[c]) for c in df.columns]
    cap = caption.replace("_", "\\_")  # captions may hold math ($\mu$s), so only _ is escaped
    lab = label.replace("_", "-")
    cols = "".join("r" if n else "l" for n in num)
    lines = [r"\begin{table}[htbp]", r"\centering", r"\caption{" + cap + "}", r"\label{" + lab + "}"]
    tab = [r"\begin{tabular}{" + cols + "}", r"\toprule",
           " & ".join(tex_escape(c) for c in df.columns) + r" \\", r"\midrule"]
    tab += [" & ".join(cell(v) for v in row) + r" \\" for row in df.itertuples(index=False)]
    tab += [r"\bottomrule", r"\end{tabular}"]
    if len(df.columns) >= 5:  # keep wide tables inside the text block
        tab[0] = r"\resizebox{\linewidth}{!}{" + tab[0]
        tab[-1] += "}"
    lines += tab + [r"\end{table}", ""]
    TAB.mkdir(parents=True, exist_ok=True)
    (TAB / f"{name}.tex").write_text("\n".join(lines))
    print(f"  report/tables/{name}.tex")


def short(alg: str) -> str:
    return (alg.replace("Classic-McEliece-", "McEliece-").replace("FrodoKEM-", "Frodo-")
               .replace("-SHAKE", ""))


# ------------------------------------------------------------------ E1
def e1():
    runs = latest("e1")
    if not runs:
        return print("  (no E1 results)")
    ops = ["keygen", "encaps", "decaps"]
    fig, axes = plt.subplots(len(runs), 3, figsize=(10, 3.2 * len(runs)), squeeze=False)
    for r, (arch, d) in enumerate(sorted(runs.items())):
        d = d.copy()
        d["us"] = d["median_ns"] / 1000
        order = list(dict.fromkeys(d[d.tier != "openssl"]["alg"])) + \
            [a for a in dict.fromkeys(d[d.tier == "openssl"]["alg"]) if a not in set(d[d.tier != "openssl"]["alg"])]
        for c, op in enumerate(ops):
            ax = axes[r][c]
            sub = d[d.op == op]
            tiers = [t for t in ("ref", "opt", "openssl") if t in set(sub.tier)]
            w = 0.8 / len(tiers)
            for i, t in enumerate(tiers):
                s = sub[sub.tier == t].set_index("alg")
                xs = [k for k, a in enumerate(order) if a in s.index]
                ax.bar([x + (i - (len(tiers) - 1) / 2) * w for x in xs],
                       [s.loc[order[x], "us"] for x in xs], width=w * 0.92,
                       color=TIER_COLOR[t], label=TIER_LABEL[t], edgecolor=SURFACE, linewidth=0.5)
            ax.set_yscale("log")
            ax.set_xticks(range(len(order)))
            ax.set_xticklabels([short(a) for a in order], rotation=70, ha="right", fontsize=7)
            ax.set_title(f"{op} ({arch})", fontsize=9, color=INK, loc="left")
            if c == 0:
                ax.set_ylabel("median time (µs, log scale)")
    fig.suptitle("E1: median cost per operation (log scale)", fontsize=9, x=0.01, ha="left", color=INK)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    h, l = axes[0][0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper right", ncol=len(l), fontsize=7)
    save(fig, "fig_e1_ops")

    for arch, d in sorted(runs.items()):
        t = d.pivot_table(index="alg", columns=["tier", "op"], values="median_ns", sort=False) / 1000
        t.columns = [f"{a} {b}" for a, b in t.columns]
        t = t.reset_index().rename(columns={"alg": "KEM"})
        write_tex(f"tab_e1_{arch}", t, f"E1 median time in $\\mu$s per operation ({arch}).", f"tab:e1-{arch}")
    d = next(iter(sorted(runs.items())))[1]
    sz = d[(d.tier != "openssl") & (d.op == "decaps")].drop_duplicates("alg")
    stack = d[d.tier == "opt"].groupby("alg")["stack_bytes"].max()
    sz = sz[["alg", "pk_bytes", "sk_bytes", "ct_bytes", "ss_bytes"]].copy()
    sz["peak stack (opt)"] = sz["alg"].map(stack)
    sz.columns = ["KEM", "public key (B)", "secret key (B)", "ciphertext (B)", "shared secret (B)", "peak stack (B)"]
    write_tex("tab_sizes", sz, "Object sizes in bytes and peak stack use of the optimised build.",
              "tab:sizes", fmt=lambda x: f"{x:,.0f}")


# ------------------------------------------------------------------ E2
def e2():
    runs = latest("e2")
    if not runs:
        return print("  (no E2 results)")
    arch, d = sorted(runs.items())[-1]
    ok = d[(d.ok == 1) & d.rtt_ms.notna()].copy()
    ok["ms"] = ok["total_ns"] / 1e6
    med = ok.groupby(["rtt_ms", "loss_pct", "group"], sort=False)["ms"].median().reset_index()
    groups = list(dict.fromkeys(ok.group))
    rtts = sorted(med.rtt_ms.unique())
    losses = sorted(med.loss_pct.unique())
    fig, axes = plt.subplots(1, len(rtts), figsize=(3.6 * len(rtts), 3.4), squeeze=False)
    for c, rtt in enumerate(rtts):
        ax = axes[0][c]
        w = 0.8 / len(losses)
        for i, loss in enumerate(losses):
            s = med[(med.rtt_ms == rtt) & (med.loss_pct == loss)].set_index("group")
            xs = [k for k, g in enumerate(groups) if g in s.index]
            ax.bar([x + (i - (len(losses) - 1) / 2) * w for x in xs], [s.loc[groups[x], "ms"] for x in xs],
                   width=w * 0.92, color=LOSS_COLOR[i % 3] if len(losses) > 1 else LOSS_COLOR[1],
                   label=f"{loss:g}% loss",
                   edgecolor=SURFACE, linewidth=0.5)
        ax.set_xticks(range(len(groups)))
        ax.set_xticklabels(groups, rotation=70, ha="right", fontsize=7)
        ax.set_title(f"RTT {rtt:g} ms", fontsize=9, loc="left", color=INK)
        if c == 0:
            ax.set_ylabel("median handshake time (ms)")
    axes[0][0].legend(fontsize=7, loc="upper left")
    fig.suptitle(f"E2: TLS 1.3 handshake time by key-exchange group ({arch}, MTU 1500)",
                 fontsize=9, x=0.01, ha="left", color=INK)
    fig.tight_layout()
    save(fig, "fig_e2_handshake")

    base = ok[(ok.rtt_ms == 0) & (ok.loss_pct == 0)]
    b = base.groupby("group", sort=False).agg(client_bytes=("bytes_sent", "median"),
                                              server_bytes=("bytes_received", "median"),
                                              median_ms=("ms", "median")).reset_index()
    na = d[d.note.fillna("") != ""][["group"]].drop_duplicates()
    for g in na.group:
        b.loc[len(b)] = [g, float("nan"), float("nan"), float("nan")]
    b.columns = ["group", "client sent (B)", "server sent (B)", "handshake (ms)"]
    for c in ("client sent (B)", "server sent (B)"):
        b[c] = b[c].map(lambda v: "--" if pd.isna(v) else f"{v:,.0f}")
    write_tex("tab_e2_bytes", b, f"E2 bytes on the wire and handshake time, no added delay ({arch}). "
              "Empty rows: no TLS group exists.", "tab:e2-bytes", fmt=lambda x: f"{x:,.1f}")


# ------------------------------------------------------------------ E3
def e3():
    runs = latest("e3dudect")
    if runs:
        fig, axes = plt.subplots(1, len(runs), figsize=(4.8 * len(runs), 5), squeeze=False)
        for c, (arch, d) in enumerate(sorted(runs.items())):
            ax = axes[0][c]
            d = d.iloc[::-1].reset_index(drop=True)
            labels = [f"{t} {short(x)}" + (" (fixed-vs-fixed)" if str(o).endswith("-ff") else "")
                      for t, x, o in zip(d.tier, d.target, d.op)]
            colors = [TIER_COLOR.get(t, INK2) for t in d.tier]
            ax.scatter(d.max_t.clip(lower=0.1), range(len(d)), s=18, c=colors, zorder=3)
            for thr, name in ((4.5, "4.5"), (10, "10: leak")):
                ax.axvline(thr, color=INK2, linestyle="--", linewidth=0.8)
                ax.text(thr, len(d) - 0.3, name, fontsize=7, color=INK2, ha="left")
            for i, v in enumerate(d.verdict):
                if v != "no_evidence":
                    ax.text(d.max_t[i] * 1.15 + 0.1, i, v, fontsize=6.5, va="center", color=INK)
            ax.set_xscale("log")
            ax.set_yticks(range(len(d)))
            ax.set_yticklabels(labels, fontsize=7)
            ax.set_xlabel("max |t| (Welch, log scale)")
            ax.set_title(f"{arch}", fontsize=9, loc="left", color=INK)
            ax.grid(axis="y", visible=False)
        leaks = sorted({short(t) for d in runs.values() for t in d[d.verdict == "leak"].target})
        fig.suptitle("E3: dudect fixed-vs-random tests; flagged (|t| > 10): " + (", ".join(leaks) or "none"),
                     fontsize=9, x=0.01, ha="left", color=INK)
        fig.tight_layout()
        save(fig, "fig_e3_dudect")
    for arch, v in sorted(latest("e3valgrind").items()):
        v = v[["alg", "contexts_raw", "errors_after_upstream_suppressions", "upstream_known_issue", "functions"]]
        v = v.assign(functions=v.functions.fillna("").str.replace(";", ", ").str.slice(0, 60))
        v.columns = ["KEM", "findings (contexts)", "after upstream suppressions", "known upstream", "first functions"]
        write_tex(f"tab_e3_valgrind_{arch}", v, f"E3 Valgrind secret-dependence findings ({arch}).",
                  f"tab:e3-valgrind-{arch}", fmt=lambda x: f"{x:,.0f}")
    for arch, s in sorted(latest("e3divscan").items()):
        p = s.pivot_table(index=["variant", "function"], columns="opt_level", values="div_instructions").reset_index()
        write_tex(f"tab_e3_divscan_{arch}", p, f"DIV instructions emitted in the KyberSlash functions ({arch}, "
                  f"{s.compiler.iloc[0]}).", f"tab:e3-div-{arch}", fmt=lambda x: f"{x:.0f}")


# ------------------------------------------------------------------ E4
def e4():
    for arch, d in sorted(latest("e4").items()):
        p = d.pivot_table(index="alg", columns="check", values="passed", aggfunc="sum", sort=False)
        tot = d.pivot_table(index="alg", columns="check", values="total", aggfunc="sum", sort=False)
        cell = p.astype("Int64").astype(str) + "/" + tot.astype("Int64").astype(str)
        cell = cell.where(tot.notna(), "--").reset_index().rename(columns={"alg": "KEM"})
        write_tex(f"tab_e4_{arch}", cell, f"E4 correctness checks passed, summed over the ref and opt builds ({arch}).", f"tab:e4-{arch}")


if __name__ == "__main__":
    print("Figures and tables:")
    for f in (e1, e2, e3, e4):
        f()
