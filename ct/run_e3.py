#!/usr/bin/env python3
"""E3 -- constant-time analysis (RQ3).

Three independent checks, each written to its own CSV in results/raw/:

  e3dudect   Statistical timing test (dudect, fixed-vs-random decapsulation)
             * controls first: a planted leaky comparison that MUST be flagged
               and a constant-time one that should not be; if the leaky
               control is missed, KEM verdicts on this machine are void
             * liboqs ref and opt builds for E3_KEMS
             * Botan's implementation of the same KEMs (tier "botan"; no HQC)
             * KyberSlash control: pq-crystals Kyber768 before/after the fix,
               at -O0/-Os/-O2/-O3
  e3divscan  Static check: DIV instructions the compiler emitted in the
             Kyber functions KyberSlash is about (poly_tomsg, poly_compress),
             and in every function of Botan's ML-KEM code
  e3valgrind Secret-dependent branches/addresses found by Valgrind memcheck
             (liboqs' ct build + test_kem, random bytes marked secret), raw and
             after applying liboqs' own list of known issues; and Botan's
             --with-valgrind build, where Botan's own CT::poison annotations
             mark the secrets (column impl). Skipped with a note when Valgrind
             or the ct builds are missing.

BOTAN_ONLY=1 runs only the Botan parts and merges them into this machine's
newest e3dudect/e3divscan/e3valgrind files.

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
    if r.returncode == 3 and r.stdout.startswith("unsupported"):
        print(f"  {'botan':<9} {cmd[1]:<28} not implemented in Botan")
        return None
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
    if pqlib.BOTAN_ONLY:
        rows = []  # controls were checked for this session; the file keeps its original ones

    if not pqlib.BOTAN_ONLY:
        print("liboqs decapsulation (fixed vs random ciphertext):")
    for tier in pqlib.TIERS if not pqlib.BOTAN_ONLY else []:
        for alg in kems:
            exe, b = str(pqlib.BIN / f"dudect_kem-{tier}"), str(budget(60))
            rows += dudect([exe, alg, b], {"opt_level": "O3"}, follow_up=[exe, alg, b, "ff"])

    botan = pqlib.BIN / "dudect_botan"
    if botan.exists():
        print("Botan decapsulation (fixed vs random ciphertext):")
        for alg in kems:
            b = str(budget(60))
            rows += dudect([str(botan), alg, b], {"opt_level": "O3"}, follow_up=[str(botan), alg, b, "ff"])
    else:
        print("  ! bin/dudect_botan missing: Botan dudect skipped")

    if pqlib.BOTAN_ONLY:
        return rows
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
    return rows + run_divscan_botan(objdump)


def run_divscan_botan(objdump):
    """DIV instructions in Botan's ML-KEM object files, per function. Botan is
    built with its default flags (-O3); its ML-KEM code is in the objects of
    the kyber module (common code, ML-KEM, and the AVX2 path on x86-64)."""
    objs = sorted((pqlib.BUILD / "botan.build" / "build" / "obj" / "lib").glob("pubkey_kyber_*.o"))
    if not objs:
        print("  ! Botan object files not found: skipping Botan DIV scan")
        return []
    fn_re = re.compile(r"^[0-9a-f]+ <(.+)>:$")  # demangled C++ names contain '<' and '>'
    counts, fn = {}, None
    for obj in objs:
        out = subprocess.run([objdump, "-d", "-C", "--no-show-raw-insn", str(obj)],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = fn_re.match(line)
            if m:
                fn = m.group(1)
                counts.setdefault(fn, 0)
            elif fn and DIV_RE.search(line + " "):
                counts[fn] += 1
    cc = subprocess.run([os.environ.get("CC", "cc"), "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    hits = {f: n for f, n in counts.items() if n}
    rows = [dict(variant="botan", opt_level="default", function=f[:120], div_instructions=n, compiler=cc)
            for f, n in sorted(hits.items())]
    rows.append(dict(variant="botan", opt_level="default", function=f"(all {len(counts)} ML-KEM functions)",
                     div_instructions=sum(counts.values()), compiler=cc))
    print(f"  Botan ML-KEM: {sum(counts.values())} DIV instructions in {len(counts)} functions"
          + (": " + ", ".join(f"{f[:60]}={n}" for f, n in hits.items()) if hits else ""))
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
        rows.append(dict(impl="liboqs", alg=alg, errors_raw=raw[0], contexts_raw=raw[1],
                         errors_after_upstream_suppressions=known[0],
                         upstream_known_issue=bool(issues.get(alg)),
                         valgrind_crashed=raw[2], functions=";".join(raw[3][:6])))
        print(f"  {alg:<26} raw contexts={raw[1]:>4}  after upstream suppressions errors={known[0]:>4}"
              f"  known issue upstream={bool(issues.get(alg))}" + ("  (valgrind crashed)" if raw[2] else ""))
    return rows


def run_valgrind_botan(kems):
    """Botan's own annotations (build/botan-ct). No suppressions exist, so the
    'after suppressions' column equals the raw one."""
    exe = pqlib.BIN / "botan_ct_kem"
    if not shutil.which("valgrind") or not exe.exists():
        print("  ! Valgrind or bin/botan_ct_kem (needs build/botan-ct) missing: skipping Botan")
        return []
    # Positive control: a deliberate branch on a CT::poison'ed byte must be found.
    errors, contexts, crashed, fns = valgrind_run(exe, "control", [])
    rows = [dict(impl="botan", alg="control (planted secret branch)", errors_raw=errors, contexts_raw=contexts,
                 errors_after_upstream_suppressions=errors, upstream_known_issue=False,
                 valgrind_crashed=crashed, functions=";".join(fns[:6]))]
    print(f"  botan  control (must be >= 1)       contexts={contexts:>4}")
    if contexts < 1:
        print("  !! Botan's CT::poison annotations are not active: Botan Valgrind results are void")
    for alg in kems:
        if subprocess.run([str(exe), alg], capture_output=True).returncode == 3:
            print(f"  botan  {alg:<26} not implemented in Botan")
            continue
        errors, contexts, crashed, fns = valgrind_run(exe, alg, [])
        rows.append(dict(impl="botan", alg=alg, errors_raw=errors, contexts_raw=contexts,
                         errors_after_upstream_suppressions=errors, upstream_known_issue=False,
                         valgrind_crashed=crashed, functions=";".join(fns[:6])))
        print(f"  botan  {alg:<26} contexts={contexts:>4}  errors={errors:>4}" + ("  (valgrind crashed)" if crashed else ""))
    return rows


def main():
    kems = [k for k in os.environ.get("E3_KEMS", ",".join(DEFAULT_E3_KEMS)).split(",") if k]
    print(f"E3 on {pqlib.arch()}: dudect budget {budget(60):.0f}s per target")
    vk = [k for k in pqlib.kems()] if not pqlib.QUICK else kems[:3]
    if pqlib.BOTAN_ONLY:
        print("BOTAN_ONLY: only Botan; rows go into this machine's newest E3 files")
        pqlib.merge_rows("e3dudect", run_dudect(kems), lambda r: r["tier"] == "botan")
        print("DIV instructions in Botan's ML-KEM code:")
        objdump = shutil.which("objdump")
        pqlib.merge_rows("e3divscan", run_divscan_botan(objdump) if objdump else [],
                         lambda r: r["variant"] == "botan")
        print("Valgrind (Botan's own annotations):")
        pqlib.merge_rows("e3valgrind", run_valgrind_botan(vk), lambda r: r.get("impl") == "botan",
                         defaults={"impl": "liboqs"})
        return
    d = run_dudect(kems)
    pqlib.write_csv(pqlib.results_path("e3dudect"), d, {"dudect_seconds": budget(60)})
    print("DIV instructions in KyberSlash-relevant functions:")
    s = run_divscan()
    if s:
        pqlib.write_csv(pqlib.results_path("e3divscan"), s)
    print("Valgrind (secret = all random bytes):")
    v = run_valgrind(vk) + run_valgrind_botan(vk)
    if v:
        pqlib.write_csv(pqlib.results_path("e3valgrind"), v)


if __name__ == "__main__":
    main()
