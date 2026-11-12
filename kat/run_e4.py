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
Botan 3 (second independent implementation; no HQC in Botan):
  kat       Botan's own known-answer tests (botan-test, its test vectors)
  acvp      ML-KEM only: the same NIST ACVP vectors through Botan
  selftest  random round trips in Botan
  botan     liboqs <-> Botan, both directions: a key made by one library,
            encapsulated by the other, decapsulated by the first
  tls       OpenSSL <-> Botan TLS 1.3 handshakes, both directions, for every
            key-exchange group both stacks offer
HQC rows for Botan are recorded as SKIP (not implemented in Botan).

Writes results/raw/e4_<arch>_<time>.csv; exits 1 if anything failed.
"""
import hashlib
import json
import re
import socket
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

ML_KEM = {"ML-KEM-512", "ML-KEM-768", "ML-KEM-1024"}
rows = []


def record(check, tier, alg, passed, total, detail="", status=None):
    ok = passed == total and total > 0
    status = status or ("PASS" if ok else "FAIL")
    rows.append(dict(check=check, tier=tier, alg=alg, passed=passed, total=total,
                     status=status, detail=detail))
    print(f"  {status:<4}  {check:<8} {tier:<9} {alg:<26} {passed}/{total} {detail}")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, **kw)


def kemtool(tier):
    return str(pqlib.BIN / f"kemtool-{tier}")


def botantool():
    return str(pqlib.BIN / "botan_kemtool")


def in_botan(alg) -> bool:
    """False for KEMs Botan does not implement (botan_kemtool exits 3)."""
    return run([botantool(), "info", alg]).returncode == 0


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
    if tier == "botan":
        exe = botantool()
        kg_cmd = lambda t: [exe, "acvp-keygen", alg, t["d"] + t["z"], t["ek"], t["dk"]]
        enc_cmd = lambda t: [exe, "acvp-encap", alg, t["m"], t["ek"], t["k"], t["c"]]
        dec_cmd = lambda t: [exe, "acvp-decap", alg, t["dk"], t["k"], t["c"]]
    else:
        exe = str(tests_dir(tier) / "vectors_kem")
        kg_cmd = lambda t: [exe, alg, "keyGen", t["d"] + t["z"], t["ek"], t["dk"]]
        enc_cmd = lambda t: [exe, alg, "encDecAFT", t["m"], t["ek"], t["k"], t["c"]]
        dec_cmd = lambda t: [exe, alg, "encDecVAL", t["dk"], t["k"], t["c"]]
    acvp = pqlib.BUILD / "acvp"
    kg = json.loads((acvp / "ML-KEM-keyGen-FIPS203.json").read_text())
    ed = json.loads((acvp / "ML-KEM-encapDecap-FIPS203.json").read_text())
    passed = total = 0
    for g in kg["testGroups"]:
        if g["parameterSet"] != alg:
            continue
        for t in g["tests"]:
            total += 1
            passed += run(kg_cmd(t)).returncode == 0
    for g in ed["testGroups"]:
        # Key-check groups (FIPS 203 7.2/7.3 input checks) are not exposed
        # by the liboqs API; liboqs' own ACVP test skips them too.
        if g["parameterSet"] != alg or g["function"] not in ("encapsulation", "decapsulation"):
            continue
        for t in g["tests"]:
            total += 1
            cmd = enc_cmd(t) if g["function"] == "encapsulation" else dec_cmd(t)
            passed += run(cmd).returncode == 0
    record("acvp", tier, alg, passed, total)


# ------------------------------------------------------------------ selftest
def check_selftest(tier, alg):
    n = 3 if "McEliece" in alg else (10 if pqlib.QUICK else 50)
    tool = botantool() if tier == "botan" else kemtool(tier)
    r = run([tool, "selftest", alg, str(n)], text=True)
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


# ------------------------------------------------------------------ Botan
def check_botan_cross(alg, d: Path):
    """liboqs <-> Botan, both directions. Only public keys, ciphertexts and
    shared secrets cross between the libraries (private keys stay with the
    library that made them), as in a real key exchange."""
    ok, detail = 0, []
    directions = (("oqs", kemtool("opt")), ("botan", botantool()))
    for (a, ta), (b, tb) in (directions, directions[::-1]):
        pk, sk, ct, s1, s2 = (d / f"x_{a}_{x}" for x in ("pk", "sk", "ct", "s1", "s2"))
        steps = [[ta, "keygen", alg, pk, sk], [tb, "encaps", alg, pk, ct, s1], [ta, "decaps", alg, sk, ct, s2]]
        results = [run(list(map(str, s))) for s in steps]
        if all(r.returncode == 0 for r in results) and s1.read_bytes() == s2.read_bytes():
            ok += 1
        else:
            bad = next((r for r in results if r.returncode), None)
            detail.append(f"{a}-key/{b}-encaps failed" +
                          (": " + bad.stderr.decode(errors="replace").strip()[:100] if bad else ": secrets differ"))
    record("botan", "opt<->botan", alg, ok, 2, "; ".join(detail))


BOTAN_KAT_TESTS = ["ml_kem_kat", "frodo_kat_tests", "cmce_generic_kat"]  # botan-test suite names
KAT_LINE = re.compile(r"PQC KAT for \S+ with parameters (\S+) ran (\d+) tests in .*?(all ok|(\d+) FAILED)")


def botan_test():
    exe = pqlib.BUILD / "botan.build" / "botan-test"
    data = pqlib.BUILD / "src" / "botan" / "src" / "tests" / "data"
    return exe, data


def check_botan_kat(algs):
    """Botan's own known-answer tests (its own vector files), one row per KEM
    of the study. --run-long-tests is needed for McEliece-460896/6688128."""
    exe, data = botan_test()
    if not exe.exists():
        record("kat", "botan", "(all)", 0, 0, "botan-test not built")
        return
    r = run([str(exe), "--run-long-tests", f"--data-dir={data}"] + BOTAN_KAT_TESTS, text=True)
    found = {}
    for m in KAT_LINE.finditer(r.stdout + r.stderr):
        param, ran = m.group(1), int(m.group(2))
        bad = int(m.group(4)) if m.group(4) else 0
        name = f"Classic-McEliece-{param}" if param[:1].isdigit() else param
        found[name] = (ran - bad, ran)
    for alg in algs:
        if alg in found:
            record("kat", "botan", alg, *found[alg])
        elif in_botan(alg):
            record("kat", "botan", alg, 0, 0, "no Botan KAT line for this parameter set")


# OpenSSL group name -> Botan group name, for groups both TLS stacks offer.
TLS_PAIRS = {"x25519": "x25519", "X25519MLKEM768": "x25519/ML-KEM-768",
             "MLKEM512": "ML-KEM-512", "MLKEM768": "ML-KEM-768", "MLKEM1024": "ML-KEM-1024"}


def free_port() -> int:
    """A currently unused TCP port (botan tls_server does not set SO_REUSEADDR,
    so a fixed port can still be in TIME_WAIT from a previous run)."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


def check_tls_interop():
    """OpenSSL client -> Botan server and Botan client -> OpenSSL server, one
    TLS 1.3 handshake each way per group (3 tries allowed). Same ECDSA P-256
    certificate as E2; certificates are not verified (key exchange only)."""
    botan = pqlib.BUILD / "botan" / "bin" / "botan"
    oc, bc = pqlib.BIN / "hs_client", pqlib.BIN / "botan_hs_client"
    if not (botan.exists() and oc.exists() and bc.exists()):
        record("tls", "openssl<->botan", "(all)", 0, 0, "Botan CLI or TLS clients missing", status="SKIP")
        return
    ossl, env = pqlib.openssl_bin(), pqlib.openssl_env()
    op = free_port()
    bp = free_port()
    while bp == op:
        bp = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        key, crt, pol = Path(tmp, "key.pem"), Path(tmp, "cert.pem"), Path(tmp, "botan.policy")
        run([ossl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
             "-keyout", key, "-out", crt, "-days", "30", "-subj", "/CN=pq-kem-study"], env=env)
        pol.write_text("allow_tls12 = false\nallow_tls13 = true\n"
                       f"key_exchange_groups = {' '.join(TLS_PAIRS.values())}\n"
                       "new_session_tickets_upon_handshake_success = 0\n")
        servers = [
            subprocess.Popen([ossl, "s_server", "-accept", str(op), "-cert", str(crt), "-key", str(key),
                              "-tls1_3", "-num_tickets", "0", "-quiet", "-groups", ":".join(TLS_PAIRS),
                              "-provider", "default"], env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
            subprocess.Popen([str(botan), "tls_server", str(crt), str(key), f"--port={bp}", f"--policy={pol}"],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
        try:
            if not (wait_port(op) and wait_port(bp)):
                record("tls", "openssl<->botan", "(all)", 0, 0, "a TLS server did not start")
                return
            for og, bg in TLS_PAIRS.items():
                ok, detail = 0, []
                for client, port, group, name in ((oc, bp, og, "openssl-client/botan-server"),
                                                  (bc, op, bg, "botan-client/openssl-server")):
                    r = run([str(client), "127.0.0.1", str(port), group, "3"], text=True, env=env, timeout=60)
                    if any(l.split(",")[2] == "1" for l in r.stdout.splitlines() if l.count(",") >= 7):
                        ok += 1
                    else:
                        detail.append(f"{name} failed: {r.stderr.strip()[:100]}")
                record("tls", "openssl<->botan", f"{og} / {bg}", ok, 2, "; ".join(detail))
        finally:
            for p in servers:
                p.terminate()


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
    if Path(botantool()).exists():
        print("Botan:")
        check_botan_kat(algs)
        with tempfile.TemporaryDirectory() as tmp:
            for alg in algs:
                if not in_botan(alg):
                    record("botan", "botan", alg, 0, 0, "not implemented in Botan", status="SKIP")
                    continue
                d = Path(tmp) / alg
                d.mkdir()
                check_selftest("botan", alg)
                if alg in ML_KEM:
                    check_acvp("botan", alg)
                check_botan_cross(alg, d)
        check_tls_interop()
    else:
        print("  (bin/botan_kemtool missing: Botan checks skipped; run `make deps tools`)")
    out = pqlib.results_path("e4")
    pqlib.write_csv(out, rows)
    failed = [r for r in rows if r["status"] not in ("PASS", "SKIP")]
    print(f"E4: {len(rows) - len(failed)}/{len(rows)} checks passed (or skipped as not applicable)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
