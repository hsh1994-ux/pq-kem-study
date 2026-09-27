#!/usr/bin/env bash
# Mini-conference demo (about 3 minutes). Run from the repo root after `make deps tools kyber`.
#
#   1. Key-share sizes on the wire: the same TLS 1.3 handshake with a
#      classical, a hybrid and two pure post-quantum groups.
#   2. Timing leakage: the planted leak is caught in under a second; the
#      KEM decapsulation is not flagged.
#
# If anything fails live, play the recording made with `demo/demo.sh | tee demo.log`.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
export LD_LIBRARY_PATH="$BUILD_DIR/openssl/lib" OPENSSL_MODULES="$BUILD_DIR/openssl/lib/ossl-modules"

pause() { read -r -p $'\n[enter] ' _ || true; }

echo "== 1. What each key exchange costs on the wire (RTT 0, loopback MTU 1500)"
N_HS=5 GROUPS=x25519,X25519MLKEM768,MLKEM768,hqc1,frodo640shake,mceliece348864 RTTS=0 LOSSES=0 \
  QUICK=1 tls/run_e2.py | grep -E "RTT|not offered"
pause

echo "== 2. Can a statistical timing test see a leak?"
bin/dudect_planted leaky 5 | grep RESULT
bin/dudect_planted ct 10 | grep RESULT
bin/dudect_kem-opt ML-KEM-768 20 | grep RESULT
echo
echo "Planted early-exit comparison: flagged. Constant-time comparison and ML-KEM decapsulation: no evidence."
