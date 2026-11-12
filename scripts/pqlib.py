"""Shared helpers for the experiment drivers (paths, KEM list, CSV output)."""
import csv
import datetime as _dt
import os
import platform
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("BUILD_DIR", ROOT / "build"))
BIN = ROOT / "bin"
RAW = ROOT / "results" / "raw"
TIERS = ("ref", "opt")
QUICK = os.environ.get("QUICK", "0") == "1"


def arch() -> str:
    return platform.machine()


def kems() -> list[str]:
    """KEM names from kems.conf, in order (override with KEMS='a,b')."""
    if os.environ.get("KEMS"):
        return [k.strip() for k in os.environ["KEMS"].split(",") if k.strip()]
    out = []
    for line in (ROOT / "kems.conf").read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def openssl_env() -> dict:
    env = dict(os.environ)
    lib = str(BUILD / "openssl" / "lib")
    env["LD_LIBRARY_PATH"] = lib + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
    env["OPENSSL_MODULES"] = str(BUILD / "openssl" / "lib" / "ossl-modules")
    return env


def openssl_bin() -> str:
    return str(BUILD / "openssl" / "bin" / "openssl")


def sysinfo_header(extra: dict | None = None) -> str:
    hdr = subprocess.run([str(ROOT / "scripts" / "sysinfo.sh")], capture_output=True, text=True).stdout
    for k, v in (extra or {}).items():
        hdr += f"# {k}={v}\n"
    return hdr


def results_path(exp: str) -> Path:
    RAW.mkdir(parents=True, exist_ok=True)
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    suffix = "_quick" if QUICK else ""
    return RAW / f"{exp}_{arch()}_{stamp}{suffix}.csv"


def write_csv(path: Path, rows: list[dict], header_extra: dict | None = None) -> None:
    if not rows:
        raise SystemExit(f"no rows to write to {path}")
    with open(path, "w", newline="") as f:
        f.write(sysinfo_header(header_extra))
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {path.relative_to(ROOT)} ({len(rows)} rows)")


# ---------------------------------------------------------------- Botan-only runs
# BOTAN_ONLY=1 makes every experiment run only its Botan part and merge the
# rows into this machine's newest (non-quick) result file of that experiment,
# replacing any Botan rows already there. Used to add Botan to an existing
# set of liboqs/OpenSSL results without re-measuring those.
BOTAN_ONLY = os.environ.get("BOTAN_ONLY", "0") == "1"


def latest_result(exp: str) -> Path:
    """Newest non-quick results/raw/<exp>_<arch>_*.csv (names sort by time)."""
    files = [f for f in sorted(RAW.glob(f"{exp}_{arch()}_*.csv")) if not f.stem.endswith("_quick")]
    if not files:
        raise SystemExit(f"BOTAN_ONLY: no {exp} results for {arch()} in {RAW} to add Botan to; "
                         f"run the full experiment once first")
    return files[-1]


def merge_rows(exp: str, rows: list[dict], replaced, defaults: dict | None = None) -> Path:
    """Merge rows into latest_result(exp): drop old rows for which replaced(row)
    is true, give old rows any new columns (defaults, else empty), keep the
    file's header and record the addition in it."""
    import time as _time
    path = latest_result(exp)
    lines = path.read_text().splitlines()
    meta = [l for l in lines if l.startswith("#")]
    old = list(csv.DictReader(l for l in lines if not l.startswith("#")))
    kept = [r for r in old if not replaced(r)]
    for r in kept:
        for k, v in (defaults or {}).items():
            r.setdefault(k, v)
    fields = list(rows[0].keys()) if rows else list(old[0].keys())
    fields += [k for k in (old[0].keys() if old else []) if k not in fields]
    versions = {l.split("=", 1)[0][2:]: l.split("=", 1)[1] for l in meta if "=" in l}
    hdr = subprocess.run([str(ROOT / "scripts" / "sysinfo.sh")], capture_output=True, text=True).stdout
    now = {l.split("=", 1)[0][2:]: l.split("=", 1)[1] for l in hdr.splitlines() if "=" in l}
    n = sum(1 for l in meta if l.startswith("# botan_added_")) + 1
    meta.append(f"# botan_added_{n}=date {_time.strftime('%Y-%m-%dT%H:%M:%SZ', _time.gmtime())}; "
                f"botan {now.get('botan', '?')}; repo_commit {now.get('repo_commit', '?')}; "
                f"rows {len(rows)}; original run {versions.get('date', '?')}")
    with open(path, "w", newline="") as f:
        f.write("\n".join(meta) + "\n")
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", restval="")
        w.writeheader()
        w.writerows(kept + rows)
    print(f"added {len(rows)} Botan rows to {path.relative_to(ROOT)} ({len(kept) + len(rows)} rows now)")
    return path
