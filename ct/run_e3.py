#!/usr/bin/env python3
"""E3 -- constant-time analysis (RQ3).

Three independent checks, each written to its own CSV in results/raw/:

  e3dudect   Statistical timing test (dudect, fixed-vs-random decapsulation)
             * controls first: a planted leaky comparison that MUST be flagged
               and a constant-time one that should not be; if the leaky
               control is missed, KEM verdicts on this machine are void
             * liboqs ref and opt builds for E3_KEMS
             * KyberSlash control: pq-crystals Kyber768 before/after the fix,
               at -O0/-Os/-O2/-O3
  e3divscan  Static check: DIV instructions the compiler emitted in the
             Kyber functions KyberSlash is about (poly_tomsg, poly_compress)
  e3valgrind Secret-dependent branches/addresses found by Valgrind memcheck
             (liboqs' ct build + test_kem, random bytes marked secret), raw and
             after applying liboqs' own list of known issues. Skipped with a
             note when Valgrind or the ct build is missing.

Knobs: QUICK=1, DUDECT_SECONDS (per target, default 60), E3_KEMS (comma list).
"""
import csv
import io
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

# Level-1 member of each family plus every ML-KEM level: dudect on the
# slowest KEMs (HQC-5, McEliece-6688128 ref) needs hours for 10k samples.
DEFAULT_E3_KEMS = ["ML-KEM-512", "ML-KEM-768", "ML-KEM-1024", "HQC-1",
                   "FrodoKEM-640-SHAKE", "Classic-McEliece-348864"]
KYBER_OPTS = ["O0", "Os", "O2", "O3"]
DUDECT_FIELDS = ["tier", "target", "op", "timer", "measurements", "max_t", "verdict", "seconds"]
# A dudect run stops at the first |t| > 10, so one crossing is weak evidence.
# Rule used here: a flagged KEM target is re-run independently; it is reported
# as "leak" only if the re-run is flagged too, otherwise "inconclusive". A
# replicated fixed-vs-random leak is followed by a fixed-vs-fixed run (two
# different valid ciphertexts) to separate data-dependent timing from
# "repeated vs varied input" effects.
DIV_RE = re.compile(r"\t(i?div[bwlq]?|[us]div)\s")
FN_RE = re.compile(r"^[0-9a-f]+ <([^>]+)>:$")


def budget(default):
    return float(os.environ.get("DUDECT_SECONDS", 5 if pqlib.QUICK else default))


def dudect_once(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    line = next((l for l in r.stdout.splitlines() if l.startswith("RESULT,")), None)
    if not line:
        print(f"  ! {' '.join(cmd)} failed: {r.stderr.strip()[:200]}")
        return None
    row = dict(zip(DUDECT_FIELDS, line.split(",")[1:]))
    n = float(row["measurements"])
    row["tau"] = f"{float(row['max_t']) / n ** 0.5:.4f}" if n > 0 else ""  # effect size, n-independent
    return row


def show(row, note=""):
    print(f"  {row['tier']:<9} {row['target']:<28} {row['op']:<9} {row['verdict']:<13} "
          f"|t|={float(row['max_t']):7.2f}  n={int(float(row['measurements'])):>9}  {row['seconds']}s {note}")


def dudect(cmd, extra=None, replicate=True, follow_up=None):
    """One target; replicate a flag, then optionally a fixed-vs-fixed follow-up."""
    row = dudect_once(cmd)
    if not row:
        return []
    row.update(extra or {})
    row["replicate_max_t"] = ""
    rows = [row]
    if replicate and row["verdict"] == "leak":
        again = dudect_once(cmd)
        if again:
            row["replicate_max_t"] = again["max_t"]
            row["verdict"] = "leak" if again["verdict"] == "leak" else "inconclusive"
    show(row, f"(replicate |t|={row['replicate_max_t']})" if row["replicate_max_t"] else "")
    if follow_up and row["verdict"] == "leak":
        ff = dudect_once(follow_up)
        if ff:
            ff.update(extra or {})
            ff["replicate_max_t"] = ""
            show(ff, "<- fixed-vs-fixed follow-up")
            rows.append(ff)
    return rows


# ------------------------------------------------------------------ dudect
def run_dudect(kems):
    rows = []
    print("Controls (planted leak must be detected):")
    for mode in ("leaky", "ct"):
        rows += dudect([str(pqlib.BIN / "dudect_planted"), mode, str(budget(30))], {"opt_level": "O2"},
                       replicate=False)
    leaky = next((r for r in rows if r["target"] == "planted-leaky-memcmp"), None)
    if not leaky or leaky["verdict"] != "leak":
        print("  !! planted leak NOT detected: timing results on this machine are not trustworthy")

    print("liboqs decapsulation (fixed vs random ciphertext):")
    for tier in pqlib.TIERS:
        for alg in kems:
            exe, b = str(pqlib.BIN / f"dudect_kem-{tier}"), str(budget(60))
            rows += dudect([exe, alg, b], {"opt_level": "O3"}, follow_up=[exe, alg, b, "ff"])

    print("KyberSlash control (pq-crystals Kyber768 ref, before/after fix):")
    for variant in ("old", "fixed"):
        for opt in KYBER_OPTS:
            exe = pqlib.BIN / f"dudect-kyber-{variant}-{opt}"
            rows += dudect([str(exe), str(budget(60))], {"opt_level": opt},
                           follow_up=[str(exe), str(budget(60)), "ff"])
    return rows


# ------------------------------------------------------------------ DIV scan
def run_divscan():
    objdump = shutil.which("objdump")
    if not objdump:
        print("  ! objdump not found: skipping DIV scan")
        return []
    rows = []
    for variant in ("old", "fixed"):
        for opt in KYBER_OPTS:
            obj = pqlib.BUILD / f"kyber-{variant}-{opt}" / "poly.o"
            out = subprocess.run([objdump, "-d", "--no-show-raw-insn", str(obj)],
                                 capture_output=True, text=True).stdout
            counts, fn = {}, None
            for line in out.splitlines():
                m = FN_RE.match(line)
                if m:
                    fn = m.group(1).split("_ref_")[-1]
                elif fn and DIV_RE.search(line + " "):
                    counts[fn] = counts.get(fn, 0) + 1
            for f in ("poly_tomsg", "poly_compress"):
                rows.append(dict(variant=variant, opt_level=opt, function=f, div_instructions=counts.get(f, 0),
                                 compiler=subprocess.run([os.environ.get("CC", "cc"), "--version"],
                                                         capture_output=True, text=True).stdout.splitlines()[0]))
            print(f"  Kyber768-{variant}-{opt}: " +
                  ", ".join(f"{f}={counts.get(f, 0)}" for f in ("poly_tomsg", "poly_compress")))
    return rows


# ------------------------------------------------------------------ Valgrind
def valgrind_run(exe, alg, supps):
    cmd = ["valgrind", "--tool=memcheck", "--error-exitcode=0", "--max-stackframe=20480000",
           "--num-callers=20"] + [f"--suppressions={s}" for s in supps] + [str(exe), alg]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    err = r.stderr
    m = re.search(r"ERROR SUMMARY: (\d+) errors from (\d+) contexts", err)
    errors, contexts = (int(m.group(1)), int(m.group(2))) if m else (-1, -1)
    crashed = "Unrecognised instruction" in err or "SIGILL" in err
    fns = []
    for m2 in re.finditer(r"(?:Conditional jump or move depends on uninitialised|Use of uninitialised value)"
                          r"[^\n]*\n[^\n]*at 0x[0-9A-F]+: ([^\s(]+)", err):
        if m2.group(1) not in fns:
            fns.append(m2.group(1))
    return errors, contexts, crashed, fns


def run_valgrind(kems):
    exe = pqlib.BUILD / "liboqs-ct.build" / "tests" / "test_kem"
    if not shutil.which("valgrind") or not exe.exists():
        print("  ! Valgrind or the liboqs ct build is missing: skipping "
              "(use the Docker image, or `apt install valgrind` then `make deps`)")
        return []
    ctdir = pqlib.BUILD / "src" / "liboqs" / "tests" / "constant_time" / "kem"
    issues = json.loads((ctdir / "issues.json").read_text())
    passes = json.loads((ctdir / "passes.json").read_text())
    rows = []
    for alg in kems:
        supps = [str(ctdir / "issues" / f) for f in issues.get(alg, [])] + \
                [str(ctdir / "passes" / f) for f in passes.get(alg, [])]
        raw = valgrind_run(exe, alg, [])
        known = valgrind_run(exe, alg, supps) if supps else raw
        rows.append(dict(alg=alg, errors_raw=raw[0], contexts_raw=raw[1],
                         errors_after_upstream_suppressions=known[0],
                         upstream_known_issue=bool(issues.get(alg)),
                         valgrind_crashed=raw[2], functions=";".join(raw[3][:6])))
        print(f"  {alg:<26} raw contexts={raw[1]:>4}  after upstream suppressions errors={known[0]:>4}"
              f"  known issue upstream={bool(issues.get(alg))}" + ("  (valgrind crashed)" if raw[2] else ""))
    return rows


def main():
    kems = [k for k in os.environ.get("E3_KEMS", ",".join(DEFAULT_E3_KEMS)).split(",") if k]
    print(f"E3 on {pqlib.arch()}: dudect budget {budget(60):.0f}s per target")
    d = run_dudect(kems)
    pqlib.write_csv(pqlib.results_path("e3dudect"), d, {"dudect_seconds": budget(60)})
    print("DIV instructions in KyberSlash-relevant functions:")
    s = run_divscan()
    if s:
        pqlib.write_csv(pqlib.results_path("e3divscan"), s)
    print("Valgrind (secret = all random bytes):")
    v = run_valgrind([k for k in pqlib.kems()] if not pqlib.QUICK else kems[:3])
    if v:
        pqlib.write_csv(pqlib.results_path("e3valgrind"), v)


if __name__ == "__main__":
    main()
