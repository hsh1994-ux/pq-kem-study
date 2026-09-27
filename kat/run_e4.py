#!/usr/bin/env python3
"""E4 -- correctness and interoperability (RQ4).

For each KEM in kems.conf and each liboqs build (ref, opt):
  kat       liboqs known-answer test output hashed and compared with the
            upstream reference hashes (tests/KATs/kem/kats.json)
  acvp      ML-KEM only: NIST ACVP FIPS 203 vectors (keyGen, encap AFT,
            decap VAL) through liboqs' vectors_kem
  selftest  random keygen/encaps/decaps round trips
Across implementations:
  cross     key from one build, encapsulate with the other, decapsulate with
            the first -- both directions
  openssl   ML-KEM only: liboqs <-> OpenSSL 3.5 native ML-KEM, both directions

Writes results/raw/e4_<arch>_<time>.csv; exits 1 if anything failed.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

ML_KEM = {"ML-KEM-512", "ML-KEM-768", "ML-KEM-1024"}
rows = []


def record(check, tier, alg, passed, total, detail=""):
    ok = passed == total and total > 0
    rows.append(dict(check=check, tier=tier, alg=alg, passed=passed, total=total,
                     status="PASS" if ok else "FAIL", detail=detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {check:<8} {tier:<9} {alg:<26} {passed}/{total} {detail}")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def kemtool(tier):
    return str(pqlib.BIN / f"kemtool-{tier}")


def tests_dir(tier):
    return pqlib.BUILD / f"liboqs-{tier}.build" / "tests"


# ------------------------------------------------------------------ KAT
def check_kat(tier, alg, kats):
    exe = tests_dir(tier) / "kat_kem"
    if alg not in kats:
        return record("kat", tier, alg, 0, 0, "no reference hash upstream")
    out = run([str(exe), alg]).stdout.replace(b"\r\n", b"\n")
    ok = hashlib.sha256(out).hexdigest() == kats[alg]["single"]
    record("kat", tier, alg, int(ok), 1)


# ------------------------------------------------------------------ ACVP
def check_acvp(tier, alg):
    exe = str(tests_dir(tier) / "vectors_kem")
    acvp = pqlib.BUILD / "acvp"
    kg = json.loads((acvp / "ML-KEM-keyGen-FIPS203.json").read_text())
    ed = json.loads((acvp / "ML-KEM-encapDecap-FIPS203.json").read_text())
    passed = total = 0
    for g in kg["testGroups"]:
        if g["parameterSet"] != alg:
            continue
        for t in g["tests"]:
            total += 1
            passed += run([exe, alg, "keyGen", t["d"] + t["z"], t["ek"], t["dk"]]).returncode == 0
    for g in ed["testGroups"]:
        # Key-check groups (FIPS 203 7.2/7.3 input checks) are not exposed
        # by the liboqs API; liboqs' own ACVP test skips them too.
        if g["parameterSet"] != alg or g["function"] not in ("encapsulation", "decapsulation"):
            continue
        for t in g["tests"]:
            total += 1
            if g["function"] == "encapsulation":
                cmd = [exe, alg, "encDecAFT", t["m"], t["ek"], t["k"], t["c"]]
            else:
                cmd = [exe, alg, "encDecVAL", t["dk"], t["k"], t["c"]]
            passed += run(cmd).returncode == 0
    record("acvp", tier, alg, passed, total)


# ------------------------------------------------------------------ selftest
def check_selftest(tier, alg):
    n = 3 if "McEliece" in alg else (10 if pqlib.QUICK else 50)
    r = run([kemtool(tier), "selftest", alg, str(n)], text=True)
    passed = int(r.stdout.split()[2].split("/")[0]) if r.returncode in (0, 1) and r.stdout else 0
    record("selftest", tier, alg, passed, n)


# ------------------------------------------------------------------ cross
def check_cross(alg, d: Path):
    ok = 0
    for a, b in (("ref", "opt"), ("opt", "ref")):
        pk, sk, ct, s1, s2 = (d / f"{x}_{a}" for x in ("pk", "sk", "ct", "s1", "s2"))
        steps = [
            [kemtool(a), "keygen", alg, pk, sk],
            [kemtool(b), "encaps", alg, pk, ct, s1],
            [kemtool(a), "decaps", alg, sk, ct, s2],
        ]
        if all(run(list(map(str, s))).returncode == 0 for s in steps):
            ok += s1.read_bytes() == s2.read_bytes()
    record("cross", "ref<->opt", alg, ok, 2)


# ------------------------------------------------------------------ OpenSSL
def check_openssl(alg, d: Path):
    ossl, env = pqlib.openssl_bin(), pqlib.openssl_env()
    oalg = alg  # OpenSSL 3.5 uses the same names: ML-KEM-512/768/1024
    ok, detail = 0, []

    # SPKI DER prefix for this parameter set, taken from an OpenSSL key.
    priv = d / "ossl_sk.pem"
    pub_der = d / "ossl_pk.der"
    r1 = run([ossl, "genpkey", "-algorithm", oalg, "-out", priv], env=env)
    r2 = run([ossl, "pkey", "-in", priv, "-pubout", "-outform", "DER", "-out", pub_der], env=env)
    if r1.returncode or r2.returncode:
        record("openssl", "opt", alg, 0, 2, "OpenSSL has no " + oalg)
        return
    info = run([kemtool("opt"), "info", alg], text=True).stdout
    pk_len = int(dict(l.split("=") for l in info.split())["pk_bytes"])
    der = pub_der.read_bytes()
    prefix = der[:-pk_len]

    # (a) OpenSSL key -> liboqs encaps -> OpenSSL decaps
    (d / "ossl_pk.raw").write_bytes(der[-pk_len:])
    r = run([kemtool("opt"), "encaps", alg, d / "ossl_pk.raw", d / "ct_a", d / "ss_a_oqs"])
    r2 = run([ossl, "pkeyutl", "-decap", "-inkey", priv, "-in", d / "ct_a",
              "-secret", d / "ss_a_ossl"], env=env)
    if r.returncode == 0 and r2.returncode == 0 and \
            (d / "ss_a_oqs").read_bytes() == (d / "ss_a_ossl").read_bytes():
        ok += 1
    else:
        detail.append("ossl-key/oqs-encaps failed: " + r2.stderr.decode(errors="replace")[:120])

    # (b) liboqs key -> OpenSSL encaps -> liboqs decaps
    run([kemtool("opt"), "keygen", alg, d / "oqs_pk.raw", d / "oqs_sk.raw"])
    (d / "oqs_pk.der").write_bytes(prefix + (d / "oqs_pk.raw").read_bytes())
    r = run([ossl, "pkeyutl", "-encap", "-pubin", "-inkey", d / "oqs_pk.der", "-keyform", "DER",
             "-out", d / "ct_b", "-secret", d / "ss_b_ossl"], env=env)
    r2 = run([kemtool("opt"), "decaps", alg, d / "oqs_sk.raw", d / "ct_b", d / "ss_b_oqs"])
    if r.returncode == 0 and r2.returncode == 0 and \
            (d / "ss_b_oqs").read_bytes() == (d / "ss_b_ossl").read_bytes():
        ok += 1
    else:
        detail.append("oqs-key/ossl-encaps failed: " + r.stderr.decode(errors="replace")[:120])
    record("openssl", "opt", alg, ok, 2, "; ".join(detail))


def main():
    kats = json.loads((pqlib.BUILD / "src" / "liboqs" / "tests" / "KATs" / "kem" / "kats.json").read_text())
    algs = pqlib.kems()
    print(f"E4 correctness on {pqlib.arch()}: {len(algs)} KEMs x {len(pqlib.TIERS)} builds")
    for tier in pqlib.TIERS:
        for alg in algs:
            check_kat(tier, alg, kats)
            check_selftest(tier, alg)
            if alg in ML_KEM:
                check_acvp(tier, alg)
    with tempfile.TemporaryDirectory() as tmp:
        for alg in algs:
            d = Path(tmp) / alg
            d.mkdir()
            check_cross(alg, d)
            if alg in ML_KEM:
                check_openssl(alg, d)
    out = pqlib.results_path("e4")
    pqlib.write_csv(out, rows)
    failed = [r for r in rows if r["status"] != "PASS"]
    print(f"E4: {len(rows) - len(failed)}/{len(rows)} checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
