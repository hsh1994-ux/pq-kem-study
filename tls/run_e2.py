#!/usr/bin/env python3
"""E2 -- TLS 1.3 handshake cost under emulated network conditions (RQ2).

The whole experiment runs inside a private network namespace, so it never
touches the host's network: `unshare -rn` (no root needed) or `unshare -n`
when already root. Docker forbids unshare by default, but a container (on
its default network) already has a private namespace, so E2 uses that; it
needs --cap-add=NET_ADMIN to change lo's MTU and add tc netem.

Inside the namespace:
  * loopback MTU is set to 1500 (Ethernet), so large key shares are split
    into realistic packets instead of one 64 KiB loopback frame
  * `tc netem` adds RTT/2 delay and packet loss on lo (every packet crosses
    lo once, so RTT = 2 x delay, and loss applies in both directions)
  * one `openssl s_server` offers all groups; bin/hs_client offers exactly
    one group per run, so that group is what gets negotiated
  * the same again with Botan's TLS 1.3 stack: `botan tls_server` (Botan's
    CLI) and bin/botan_hs_client, under the same delay/loss, in the same cell.
    Botan rows have stack=botan and group "botan:<Botan group name>". Botan's
    FrodoKEM TLS groups are eFrodoKEM (the ephemeral variant, no salt): a
    slightly smaller ciphertext than the FrodoKEM of E1/E4. Botan has no HQC
    and, like everyone, no Classic McEliece TLS group.

Environment knobs: QUICK=1, N_HS (handshakes per cell), E2_GROUPS (comma list),
E2_BOTAN_GROUPS (comma list, Botan names), E2_STACKS (default openssl,botan),
RTTS (ms, comma list), LOSSES (%, comma list), MTU (default 1500).
Writes results/raw/e2_<arch>_<time>.csv.
"""
import csv
import io
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import pqlib  # noqa: E402

PORT = 4433
BOTAN_PORT = 4434
# Classical baseline, deployed hybrid, pure ML-KEM (OpenSSL native), then
# oqs-provider groups. Unavailable groups are recorded as such, not dropped.
DEFAULT_GROUPS = [
    "x25519", "X25519MLKEM768", "MLKEM512", "MLKEM768", "MLKEM1024",
    "hqc1", "hqc3", "hqc5",
    "frodo640shake", "frodo976shake", "frodo1344shake",
    # Classic McEliece has no TLS group: a 261 KB public key cannot fit in a
    # ClientHello key share (max 65,535 bytes). Kept so the CSV records it.
    "mceliece348864",
]
BOTAN_GROUPS = [
    "x25519", "x25519/ML-KEM-768", "ML-KEM-512", "ML-KEM-768", "ML-KEM-1024",
    "eFrodoKEM-640-SHAKE", "eFrodoKEM-976-SHAKE", "eFrodoKEM-1344-SHAKE",
]
# Recorded as rows with a note, so the CSV says why they are missing.
BOTAN_NOT_AVAILABLE = {"HQC": "not implemented in Botan",
                       "Classic-McEliece": "group not available in TLS"}
FIELDS = ["group", "i", "ok", "tcp_ns", "tls_ns", "total_ns", "bytes_sent", "bytes_received"]


def csv_list(name, default):
    v = os.environ.get(name)
    return [x.strip() for x in v.split(",") if x.strip()] if v else default


def sh(*cmd, check=True):
    r = subprocess.run(list(map(str, cmd)), capture_output=True, text=True, env=pqlib.openssl_env())
    if check and r.returncode:
        raise SystemExit(f"{' '.join(map(str, cmd))} failed: {r.stderr.strip()}")
    return r


def in_private_container_netns() -> bool:
    """True inside a container that has its own network namespace (Docker's
    default bridge network), where changing lo cannot affect the host."""
    in_container = os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv")
    host_net = any(os.path.exists(f"/sys/class/net/{i}") for i in ("docker0", "cni0", "br-lan"))
    return in_container and not host_net


def reexec_in_netns():
    cmd = ["unshare", "-n"] if os.geteuid() == 0 else ["unshare", "-rn"]
    env = dict(os.environ, E2_IN_NS="1")
    # Docker's default seccomp profile refuses unshare without CAP_SYS_ADMIN, but a
    # container already has a private network namespace: use that one instead.
    probe = subprocess.run(cmd + ["true"], capture_output=True, text=True)
    if probe.returncode != 0:
        if in_private_container_netns():
            print("  (unshare not permitted in this container; using the container's own "
                  "private network namespace)")
            os.environ["E2_IN_NS"] = "1"
            return
        raise SystemExit(f"cannot create a network namespace ({probe.stderr.strip()}); run on Linux "
                         "with unprivileged user namespaces, or in Docker with --cap-add=NET_ADMIN")
    try:
        os.execvpe(cmd[0], cmd + [sys.executable, __file__] + sys.argv[1:], env)
    except OSError as e:
        raise SystemExit(f"cannot create a network namespace ({e}); "
                         "run in Docker with --cap-add=NET_ADMIN") from e


def available_groups() -> set[str]:
    out = sh(pqlib.openssl_bin(), "list", "-tls-groups", "-tls1_3",
             "-provider", "default", "-provider", "oqsprovider", check=False).stdout
    return {g.strip() for g in out.replace("\n", ":").split(":") if g.strip()}


def wait_port(port, timeout=10, what="s_server"):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise SystemExit(f"{what} did not start")


def botan_cli() -> Path:
    return pqlib.BUILD / "botan" / "bin" / "botan"


def start_botan_server(tmp, crt, key, groups):
    """Botan's own TLS 1.3 server (its CLI), offering every Botan group."""
    policy = Path(tmp, "botan_server.policy")
    policy.write_text("allow_tls12 = false\nallow_tls13 = true\n"
                      f"key_exchange_groups = {' '.join(groups)}\n"
                      "new_session_tickets_upon_handshake_success = 0\n")
    p = subprocess.Popen([str(botan_cli()), "tls_server", str(crt), str(key), f"--port={BOTAN_PORT}",
                          f"--policy={policy}"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_port(BOTAN_PORT, what="botan tls_server")
    return p


def handshakes(client, port, group, n_hs, label, rtt, loss, mtu, stack):
    """Run one client for one group in the current netem cell; returns CSV rows."""
    r = subprocess.run([str(client), "127.0.0.1", str(port), group, str(n_hs)],
                       capture_output=True, text=True, env=pqlib.openssl_env(), timeout=900)
    got = list(csv.DictReader(io.StringIO(r.stdout), fieldnames=FIELDS))
    oks = [x for x in got if x["ok"] == "1"]
    med = sorted(int(x["total_ns"]) for x in oks)[len(oks) // 2] / 1e6 if oks else float("nan")
    sent = oks[0]["bytes_sent"] if oks else "-"
    print(f"  RTT {rtt:5.0f} ms loss {loss:3.0f}%  {label:<26} "
          f"{len(oks)}/{n_hs} ok  median {med:8.2f} ms  client sent {sent} B")
    return [dict(stack=stack, group=label, rtt_ms=rtt, loss_pct=loss, mtu=mtu, i=x["i"], ok=x["ok"],
                 tcp_ns=x["tcp_ns"], tls_ns=x["tls_ns"], total_ns=x["total_ns"],
                 bytes_sent=x["bytes_sent"], bytes_received=x["bytes_received"], note="") for x in got]


def netem_available() -> bool:
    r = sh("tc", "qdisc", "add", "dev", "lo", "root", "netem", "delay", "1ms", check=False)
    sh("tc", "qdisc", "del", "dev", "lo", "root", check=False)
    return r.returncode == 0


def set_netem(rtt_ms, loss_pct):
    sh("tc", "qdisc", "del", "dev", "lo", "root", check=False)
    if rtt_ms or loss_pct:
        sh("tc", "qdisc", "add", "dev", "lo", "root", "netem",
           "delay", f"{rtt_ms / 2}ms", "loss", f"{loss_pct}%")


def main():
    if os.environ.get("E2_IN_NS") != "1":
        reexec_in_netns()

    quick = pqlib.QUICK
    n_hs = int(os.environ.get("N_HS", 10 if quick else 200))
    rtts = [float(x) for x in csv_list("RTTS", ["0", "50"] if quick else ["0", "50", "200"])]
    losses = [float(x) for x in csv_list("LOSSES", ["0", "1"] if quick else ["0", "1", "3"])]
    mtu = int(os.environ.get("MTU", 1500))
    # E2_GROUPS, not GROUPS: bash has a read-only GROUPS variable, so GROUPS=... never arrives.
    groups = csv_list("E2_GROUPS", DEFAULT_GROUPS)
    stacks = csv_list("E2_STACKS", ["openssl", "botan"])
    bgroups = csv_list("E2_BOTAN_GROUPS", BOTAN_GROUPS)
    if "botan" in stacks and not (botan_cli().exists() and (pqlib.BIN / "botan_hs_client").exists()):
        print("  ! Botan (build/botan/bin/botan or bin/botan_hs_client) missing: Botan stack skipped")
        stacks = [x for x in stacks if x != "botan"]

    sh("ip", "link", "set", "lo", "up")
    sh("ip", "link", "set", "lo", "mtu", mtu)
    netem = netem_available()
    if not netem:
        print("  ! tc netem is not available in this kernel: only RTT 0 / loss 0 is measured.")
        print("    (Run on a kernel with sch_netem, e.g. the Docker image or most Linux distros.)")
        rtts, losses = [0.0], [0.0]
    have = available_groups() if "openssl" in stacks else set()
    usable = [g for g in groups if g in have] if "openssl" in stacks else []
    missing = [g for g in groups if g not in have] if "openssl" in stacks else []
    print(f"E2 on {pqlib.arch()}: stacks {stacks}, {len(usable)} OpenSSL + "
          f"{len(bgroups) if 'botan' in stacks else 0} Botan groups, RTT {rtts} ms, loss {losses} %, "
          f"{n_hs} handshakes/cell, MTU {mtu}")
    if missing:
        print(f"  not offered by OpenSSL/oqs-provider: {', '.join(missing)}")

    def note_row(stack, group, note):
        return dict(stack=stack, group=group, rtt_ms="", loss_pct="", mtu=mtu, i="", ok=0, tcp_ns="", tls_ns="",
                    total_ns="", bytes_sent="", bytes_received="", note=note)

    rows = [note_row("openssl", g, "group not available in TLS") for g in missing]
    if "botan" in stacks:
        rows += [note_row("botan", f"botan:{fam}", why) for fam, why in BOTAN_NOT_AVAILABLE.items()]

    with tempfile.TemporaryDirectory() as tmp:
        key, crt = Path(tmp, "key.pem"), Path(tmp, "cert.pem")
        # Classical ECDSA P-256 certificate: E2 isolates the key exchange.
        sh(pqlib.openssl_bin(), "req", "-x509", "-newkey", "ec", "-pkeyopt",
           "ec_paramgen_curve:P-256", "-nodes", "-keyout", key, "-out", crt,
           "-days", "30", "-subj", "/CN=pq-kem-study")
        servers = []
        try:
            if "openssl" in stacks:
                servers.append(subprocess.Popen(
                    [pqlib.openssl_bin(), "s_server", "-accept", str(PORT), "-cert", str(crt),
                     "-key", str(key), "-tls1_3", "-num_tickets", "0", "-quiet",
                     "-groups", ":".join(usable), "-provider", "default", "-provider", "oqsprovider"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    env=pqlib.openssl_env()))
                wait_port(PORT)
            if "botan" in stacks:
                servers.append(start_botan_server(tmp, crt, key, bgroups))
            # Both stacks are measured in the same netem cell, one after the other.
            for rtt in rtts:
                for loss in losses:
                    set_netem(rtt, loss)
                    for g in usable:
                        rows += handshakes(pqlib.BIN / "hs_client", PORT, g, n_hs, g, rtt, loss, mtu, "openssl")
                    if "botan" in stacks:
                        for g in bgroups:
                            rows += handshakes(pqlib.BIN / "botan_hs_client", BOTAN_PORT, g, n_hs,
                                               f"botan:{g}", rtt, loss, mtu, "botan")
        finally:
            for p in servers:
                p.terminate()
            set_netem(0, 0)

    pqlib.write_csv(pqlib.results_path("e2"), rows,
                    {"n_hs": n_hs, "mtu": mtu, "netem": "yes" if netem else "unavailable",
                     "cert": "ECDSA P-256 self-signed", "stacks": "+".join(stacks)})


if __name__ == "__main__":
    main()
