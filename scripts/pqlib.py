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
