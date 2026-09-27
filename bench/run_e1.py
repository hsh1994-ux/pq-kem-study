#!/usr/bin/env python3
"""E1 -- microbenchmarks (RQ1).

Runs bin/bench_kem-{ref,opt} for every KEM in kems.conf, plus
bin/bench_ossl for OpenSSL's own ML-KEM, X25519 and X25519MLKEM768,
and writes results/raw/e1_<arch>_<time>.csv.

Environment knobs:
  QUICK=1       few iterations (smoke test, not for the report)
  N_OPS=1000    iterations for encaps/decaps (keygen uses the same, except
                Classic McEliece which uses N_MCE_KEYGEN=20)
  COOLDOWN=0    seconds to sleep between KEMs; use ~30 on a fanless laptop
  PIN_CPU=1     core to pin to with taskset (empty to disable)
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
          "ct_bytes", "ss_bytes"]
OSSL_ALGS = ["X25519", "ML-KEM-512", "ML-KEM-768", "ML-KEM-1024", "X25519MLKEM768"]


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


def run_bench(cmd: list[str]) -> list[dict]:
    pin = os.environ.get("PIN_CPU", "1")
    if pin and shutil.which("taskset") and (os.cpu_count() or 1) > int(pin):
        cmd = ["taskset", "-c", pin] + cmd
    r = subprocess.run(cmd, capture_output=True, text=True, env=pqlib.openssl_env())
    if r.returncode != 0:
        print(f"  ! {' '.join(cmd)}: {r.stderr.strip()[:200]}")
        return []
    return list(csv.DictReader(io.StringIO(r.stdout), fieldnames=FIELDS))


def main():
    quick = pqlib.QUICK
    n_ops = env_int("N_OPS", 50 if quick else 1000)
    n_mce = env_int("N_MCE_KEYGEN", 2 if quick else 20)
    cooldown = env_int("COOLDOWN", 0)
    rows = []
    print(f"E1 on {pqlib.arch()}: N_OPS={n_ops}, McEliece keygen={n_mce}, cooldown={cooldown}s")

    for tier in pqlib.TIERS:
        for alg in pqlib.kems():
            nk = n_mce if "McEliece" in alg else n_ops
            t0 = time.time()
            got = run_bench([str(pqlib.BIN / f"bench_kem-{tier}"), alg, str(nk), str(n_ops)])
            rows += got
            for r in got:
                print(f"  {tier:<4} {alg:<26} {r['op']:<7} median {float(r['median_ns']) / 1000:10.1f} us")
            print(f"       ({time.time() - t0:.0f}s)")
            time.sleep(cooldown)

    for alg in OSSL_ALGS:
        got = run_bench([str(pqlib.BIN / "bench_ossl"), alg, str(n_ops), str(n_ops)])
        rows += got
        for r in got:
            print(f"  ossl {alg:<26} {r['op']:<7} median {float(r['median_ns']) / 1000:10.1f} us")
        time.sleep(cooldown)

    extra = cpu_state() | {"n_ops": n_ops, "n_mce_keygen": n_mce, "cooldown_s": cooldown,
                           "pin_cpu": os.environ.get("PIN_CPU", "1")}
    pqlib.write_csv(pqlib.results_path("e1"), rows, extra)


if __name__ == "__main__":
    main()
