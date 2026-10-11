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

Environment knobs: QUICK=1, N_HS (handshakes per cell), E2_GROUPS (comma list),
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


def wait_port(port, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.1)
    raise SystemExit("s_server did not start")


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

    sh("ip", "link", "set", "lo", "up")
    sh("ip", "link", "set", "lo", "mtu", mtu)
    netem = netem_available()
    if not netem:
        print("  ! tc netem is not available in this kernel: only RTT 0 / loss 0 is measured.")
        print("    (Run on a kernel with sch_netem, e.g. the Docker image or most Linux distros.)")
        rtts, losses = [0.0], [0.0]
    have = available_groups()
    usable = [g for g in groups if g in have]
    missing = [g for g in groups if g not in have]
    print(f"E2 on {pqlib.arch()}: {len(usable)} groups, RTT {rtts} ms, loss {losses} %, "
          f"{n_hs} handshakes/cell, MTU {mtu}")
    if missing:
        print(f"  not offered by OpenSSL/oqs-provider: {', '.join(missing)}")

    rows = [dict(group=g, rtt_ms="", loss_pct="", mtu=mtu, i="", ok=0, tcp_ns="", tls_ns="",
                 total_ns="", bytes_sent="", bytes_received="", note="group not available in TLS")
            for g in missing]

    with tempfile.TemporaryDirectory() as tmp:
        key, crt = Path(tmp, "key.pem"), Path(tmp, "cert.pem")
        # Classical ECDSA P-256 certificate: E2 isolates the key exchange.
        sh(pqlib.openssl_bin(), "req", "-x509", "-newkey", "ec", "-pkeyopt",
           "ec_paramgen_curve:P-256", "-nodes", "-keyout", key, "-out", crt,
           "-days", "30", "-subj", "/CN=pq-kem-study")
        server = subprocess.Popen(
            [pqlib.openssl_bin(), "s_server", "-accept", str(PORT), "-cert", str(crt),
             "-key", str(key), "-tls1_3", "-num_tickets", "0", "-quiet",
             "-groups", ":".join(usable), "-provider", "default", "-provider", "oqsprovider"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=pqlib.openssl_env())
        try:
            wait_port(PORT)
            for rtt in rtts:
                for loss in losses:
                    set_netem(rtt, loss)
                    for g in usable:
                        r = subprocess.run(
                            [str(pqlib.BIN / "hs_client"), "127.0.0.1", str(PORT), g, str(n_hs)],
                            capture_output=True, text=True, env=pqlib.openssl_env(),
                            timeout=600)
                        got = list(csv.DictReader(io.StringIO(r.stdout), fieldnames=FIELDS))
                        oks = [x for x in got if x["ok"] == "1"]
                        med = sorted(int(x["total_ns"]) for x in oks)[len(oks) // 2] / 1e6 if oks else float("nan")
                        sent = oks[0]["bytes_sent"] if oks else "-"
                        print(f"  RTT {rtt:5.0f} ms loss {loss:3.0f}%  {g:<16} "
                              f"{len(oks)}/{n_hs} ok  median {med:8.2f} ms  client sent {sent} B")
                        for x in got:
                            rows.append(dict(group=x["group"], rtt_ms=rtt, loss_pct=loss, mtu=mtu,
                                             i=x["i"], ok=x["ok"], tcp_ns=x["tcp_ns"],
                                             tls_ns=x["tls_ns"], total_ns=x["total_ns"],
                                             bytes_sent=x["bytes_sent"],
                                             bytes_received=x["bytes_received"], note=""))
        finally:
            server.terminate()
            set_netem(0, 0)

    pqlib.write_csv(pqlib.results_path("e2"), rows,
                    {"n_hs": n_hs, "mtu": mtu, "netem": "yes" if netem else "unavailable",
                     "cert": "ECDSA P-256 self-signed"})


if __name__ == "__main__":
    main()
