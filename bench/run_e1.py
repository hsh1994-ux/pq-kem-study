#!/usr/bin/env python3
"""E1 -- microbenchmarks (RQ1).

Runs bin/bench_kem-{ref,opt} for every KEM in kems.conf, plus
bin/bench_ossl for OpenSSL's own ML-KEM, X25519 (plain ECDH and DHKEM) and X25519MLKEM768,
and writes results/raw/e1_<arch>_<time>.csv.

Environment knobs:
  QUICK=1       few iterations (smoke test, not for the report)
  N_OPS=1000    iterations for encaps/decaps (keygen uses the same, except
                Classic McEliece which uses N_MCE_KEYGEN=20)
  COOLDOWN=0    seconds to sleep between KEMs; use ~30 on a fanless laptop
  PIN_CPU=1     core to pin to with taskset (empty to disable)
  WARMUP_MS=200 busy-wait before the first timed operation of each process
  KEMS=none     skip the liboqs KEMs (KEMS=a,b limits them to a subset)
  E1_OSSL=a,b   only these OpenSSL algorithms (default: all of OSSL_ALGS)
  E1_APPEND=f   add the new rows to an existing results file f instead of
                writing a new one (rows with the same tier/alg/op are
                replaced); a '# appended_N=...' header line records when, with
                which commit, and the timer calibration of the added rows.
                f must come from the same machine.

Timer calibration: bin/calibrate runs once at the start; its ns_per_tick is
passed to every benchmark process (PQ_NS_PER_TICK) and recorded in the
header with the core-clock estimate. Each row also carries ghz_before /
ghz_after (core clock estimated around its timed loop) and
median_core_cycles_est, for comparison with published cycle counts.
"""
import csv
import io
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

FIELDS = ["tier", "alg", "op", "n", "unit", "ns_per_tick", "min", "p25", "median", "p75",
          "mean", "median_ns", "p25_ns", "p75_ns", "stack_bytes", "pk_bytes", "sk_bytes",
          "ct_bytes", "ss_bytes", "ghz_before", "ghz_after", "median_core_cycles_est"]
# X25519-ECDH: plain ephemeral ECDH as in TLS 1.3; X25519-DHKEM: the same wrapped as a KEM (RFC 9180).
OSSL_ALGS = ["X25519-ECDH", "X25519-DHKEM", "ML-KEM-512", "ML-KEM-768", "ML-KEM-1024", "X25519MLKEM768"]


def env_int(name, default):
    return int(os.environ.get(name, default))


def cpu_state() -> dict:
    """Frequency-scaling state, recorded so noisy runs can be explained."""
    def read(p):
        try:
            return Path(p).read_text().strip()
        except OSError:
            return "n/a"
    return {
        "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "intel_no_turbo": read("/sys/devices/system/cpu/intel_pstate/no_turbo"),
        "cpufreq_boost": read("/sys/devices/system/cpu/cpufreq/boost"),
    }


def pinned(cmd: list[str]) -> list[str]:
    pin = os.environ.get("PIN_CPU", "1")
    if pin and shutil.which("taskset") and (os.cpu_count() or 1) > int(pin):
        return ["taskset", "-c", pin] + cmd
    return cmd


def calibrate() -> dict:
    """Run bin/calibrate once; returns ns_per_tick, tick_mhz, core_ghz (strings)."""
    r = subprocess.run(pinned([str(pqlib.BIN / "calibrate")]), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"bin/calibrate failed: {r.stderr.strip()}")
    return dict(kv.split("=", 1) for kv in r.stdout.split())


def run_bench(cmd: list[str], env: dict) -> list[dict]:
    cmd = pinned(cmd)
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(f"  ! {' '.join(cmd)}: {r.stderr.strip()[:200]}")
        return []
    return list(csv.DictReader(io.StringIO(r.stdout), fieldnames=FIELDS))


def append_rows(path: Path, rows: list[dict], note: dict) -> None:
    """Merge rows into an existing E1 file, keeping its header and recording the addition."""
    if not path.is_absolute():
        path = pqlib.ROOT / path
    if not path.exists():
        raise SystemExit(f"E1_APPEND: {path} not found")
    lines = path.read_text().splitlines()
    meta = [l for l in lines if l.startswith("#")]
    old = list(csv.DictReader(l for l in lines if not l.startswith("#")))
    arch = next((l.split("=", 1)[1] for l in meta if l.startswith("# arch=")), "")
    if arch and arch != pqlib.arch():
        raise SystemExit(f"E1_APPEND: {path.name} is from {arch}, this machine is {pqlib.arch()}")
    renamed = False
    for r in old:  # files from before the plain-ECDH baseline call the DHKEM row "X25519"
        if r["tier"] == "openssl" and r["alg"] == "X25519":
            r["alg"], renamed = "X25519-DHKEM", True
    if renamed:
        note = note | {"renamed": "X25519 -> X25519-DHKEM"}
    key = lambda r: (r["tier"], r["alg"], r["op"])
    new_keys = {key(r) for r in rows}
    merged = [r for r in old if key(r) not in new_keys] + rows
    n = sum(1 for l in meta if l.startswith("# appended_")) + 1
    meta.append(f"# appended_{n}=" + "; ".join(f"{k} {v}" for k, v in note.items()))
    fields = list(old[0].keys()) if old else FIELDS
    with open(path, "w", newline="") as f:
        f.write("\n".join(meta) + "\n")
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(merged)
    print(f"added {len(rows)} rows to {path.relative_to(pqlib.ROOT)} ({len(merged)} rows now)")


def main():
    quick = pqlib.QUICK
    n_ops = env_int("N_OPS", 50 if quick else 1000)
    n_mce = env_int("N_MCE_KEYGEN", 2 if quick else 20)
    cooldown = env_int("COOLDOWN", 0)
    rows = []
    print(f"E1 on {pqlib.arch()}: N_OPS={n_ops}, McEliece keygen={n_mce}, cooldown={cooldown}s")
    cal = calibrate()
    print(f"  timer: {cal['tick_mhz']} MHz ({cal['ns_per_tick']} ns/tick), "
          f"core clock now ~{cal['core_ghz']} GHz")
    env = pqlib.openssl_env() | {"PQ_NS_PER_TICK": cal["ns_per_tick"]}

    kems = [] if os.environ.get("KEMS", "").strip().lower() == "none" else pqlib.kems()
    ossl_algs = [a.strip() for a in os.environ.get("E1_OSSL", "").split(",") if a.strip()] or OSSL_ALGS
    for tier in pqlib.TIERS if kems else []:
        for alg in kems:
            nk = n_mce if "McEliece" in alg else n_ops
            t0 = time.time()
            got = run_bench([str(pqlib.BIN / f"bench_kem-{tier}"), alg, str(nk), str(n_ops)], env)
            rows += got
            for r in got:
                print(f"  {tier:<4} {alg:<26} {r['op']:<7} median {float(r['median_ns']) / 1000:10.1f} us"
                      f"   ~{r['ghz_before']}-{r['ghz_after']} GHz")
            print(f"       ({time.time() - t0:.0f}s)")
            time.sleep(cooldown)

    for alg in ossl_algs:
        got = run_bench([str(pqlib.BIN / "bench_ossl"), alg, str(n_ops), str(n_ops)], env)
        rows += got
        for r in got:
            print(f"  ossl {alg:<26} {r['op']:<7} median {float(r['median_ns']) / 1000:10.1f} us")
        time.sleep(cooldown)

    extra = cpu_state() | {"n_ops": n_ops, "n_mce_keygen": n_mce, "cooldown_s": cooldown,
                           "pin_cpu": os.environ.get("PIN_CPU", "1"),
                           "warmup_ms": os.environ.get("WARMUP_MS", "200"),
                           "ns_per_tick": cal["ns_per_tick"], "tick_mhz": cal["tick_mhz"],
                           "core_ghz_at_start": cal["core_ghz"]}
    target = os.environ.get("E1_APPEND", "").strip()
    if target:
        commit = subprocess.run(["git", "-C", str(pqlib.ROOT), "rev-parse", "--short", "HEAD"],
                                capture_output=True, text=True).stdout.strip() or "none"
        algs = sorted({r["alg"] for r in rows})
        append_rows(Path(target), rows, {"date": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                         "algs": ",".join(algs), "repo_commit": commit,
                                         "n_ops": n_ops, "ns_per_tick": cal["ns_per_tick"],
                                         "core_ghz_at_start": cal["core_ghz"]})
    else:
        pqlib.write_csv(pqlib.results_path("e1"), rows, extra)


if __name__ == "__main__":
    main()
