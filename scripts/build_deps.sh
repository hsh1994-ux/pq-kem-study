#!/usr/bin/env bash
# Build every third-party dependency into $BUILD_DIR (default: ./build).
#
#   openssl/       OpenSSL 3.5 (native ML-KEM + X25519MLKEM768 in TLS)
#   liboqs-ref/    liboqs, portable C only (no AVX2 / NEON)       -> "ref" tier
#   liboqs-opt/    liboqs, tuned for this CPU (AVX2 or NEON)      -> "opt" tier
#   liboqs-ct/     liboqs Debug build with constant-time tests    -> E3
#   ossl-modules/  oqs-provider (HQC, FrodoKEM, ... inside OpenSSL TLS)
#
# Works on x86-64 and ARM64 Linux. Safe to re-run: finished steps are skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/versions.env"
B="${BUILD_DIR:-$ROOT/build}"
SRC="$B/src"
JOBS="${JOBS:-$(nproc)}"
ARCH="$(uname -m)"
mkdir -p "$SRC"

log() { printf '\n==> %s\n' "$*"; }

clone() { # clone <url> <ref> <dir>
  local url=$1 ref=$2 dir=$3
  [ -d "$dir/.git" ] && return 0
  rm -rf "$dir.part" # left over from an interrupted clone
  if git ls-remote --exit-code --tags --heads "$url" "$ref" >/dev/null 2>&1; then
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$url" "$dir.part"
  else # a commit hash
    git clone -q "$url" "$dir.part" && git -C "$dir.part" checkout -q "$ref"
  fi
  mv "$dir.part" "$dir" # only a complete clone gets the final name
}

# Only the KEMs we study, to keep build time down.
KEM_LIST="KEM_ml_kem_512;KEM_ml_kem_768;KEM_ml_kem_1024;KEM_hqc_1;KEM_hqc_3;KEM_hqc_5;\
KEM_frodokem_640_shake;KEM_frodokem_976_shake;KEM_frodokem_1344_shake;\
KEM_frodokem_640_aes;KEM_frodokem_976_aes;KEM_frodokem_1344_aes;\
KEM_classic_mceliece_348864;KEM_classic_mceliece_460896;KEM_classic_mceliece_6688128"
# oqs-provider refuses to load without at least one signature algorithm.
SIG_LIST="SIG_ml_dsa_65"

# ---------------------------------------------------------------- OpenSSL
if [ ! -x "$B/openssl/bin/openssl" ]; then
  log "OpenSSL $OPENSSL_TAG"
  clone https://github.com/openssl/openssl "$OPENSSL_TAG" "$SRC/openssl"
  # Configure once; make is resumable, so an interrupted build continues.
  [ -f "$SRC/openssl/Makefile" ] || (cd "$SRC/openssl" &&
    ./Configure --prefix="$B/openssl" --libdir=lib --openssldir="$B/openssl/ssl" \
      shared no-docs no-tests >/dev/null)
  (cd "$SRC/openssl" && make -j"$JOBS" >/dev/null && make install_sw install_ssldirs >/dev/null)
fi

# ---------------------------------------------------------------- liboqs
clone https://github.com/open-quantum-safe/liboqs "$LIBOQS_TAG" "$SRC/liboqs"

build_liboqs() { # build_liboqs <name> <extra cmake args...>
  local name=$1; shift
  [ -f "$B/$name/lib/liboqs.a" ] && return 0
  log "liboqs ($name)"
  [ -f "$B/$name.build/build.ninja" ] || cmake -S "$SRC/liboqs" -B "$B/$name.build" -GNinja \
    -DCMAKE_INSTALL_PREFIX="$B/$name" -DBUILD_SHARED_LIBS=OFF \
    -DOQS_USE_OPENSSL=OFF -DOQS_DIST_BUILD=OFF \
    -DOQS_MINIMAL_BUILD="$KEM_LIST;$SIG_LIST" "$@" >/dev/null
  ninja -C "$B/$name.build" -j"$JOBS" >/dev/null
  ninja -C "$B/$name.build" install >/dev/null
}

# ref: portable C. NEON/AVX2 switched off explicitly because "generic" still
# counts NEON as baseline on ARM64.
build_liboqs liboqs-ref -DCMAKE_BUILD_TYPE=Release -DOQS_OPT_TARGET=generic \
  -DOQS_USE_AVX2_INSTRUCTIONS=OFF -DOQS_USE_ARM_NEON_INSTRUCTIONS=OFF
# opt: everything this CPU supports.
build_liboqs liboqs-opt -DCMAKE_BUILD_TYPE=Release -DOQS_OPT_TARGET=auto
# ct: same as opt, but with liboqs' constant-time annotations compiled in
# (values that are legitimately public, e.g. rejection-sampling seeds, are
# declassified for Valgrind). Optimised (-O3) so we test what ships.
# Needs Valgrind's headers; skipped with a note if they are missing.
# Valgrind cannot decode AVX-512, which -march=native emits on recent Xeons,
# so on x86-64 the CT build targets Haswell (AVX2/BMI2, no AVX-512).
CT_TARGET=auto
[ "$ARCH" = x86_64 ] && CT_TARGET=haswell
if [ -f /usr/include/valgrind/memcheck.h ]; then
  build_liboqs liboqs-ct -DCMAKE_BUILD_TYPE=Debug -DOQS_OPT_TARGET="$CT_TARGET" \
    -DOQS_ENABLE_TEST_CONSTANT_TIME=ON -DOQS_ENABLE_TEST_CONSTANT_TIME_OPTIMIZED=ON
else
  log "Valgrind headers not found: skipping liboqs-ct (E3 Valgrind part needs Docker or apt install valgrind)"
fi

# ---------------------------------------------------------------- oqs-provider
if [ ! -f "$B/openssl/lib/ossl-modules/oqsprovider.so" ]; then
  log "oqs-provider $OQSPROVIDER_TAG"
  clone https://github.com/open-quantum-safe/oqs-provider "$OQSPROVIDER_TAG" "$SRC/oqs-provider"
  [ -f "$B/oqs-provider.build/build.ninja" ] || cmake -S "$SRC/oqs-provider" -B "$B/oqs-provider.build" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="$B/openssl" \
    -Dliboqs_DIR="$B/liboqs-opt/lib/cmake/liboqs" >/dev/null
  ninja -C "$B/oqs-provider.build" -j"$JOBS" >/dev/null
  mkdir -p "$B/openssl/lib/ossl-modules"
  cp "$B/oqs-provider.build/lib/oqsprovider.so" "$B/openssl/lib/ossl-modules/"
fi

# ---------------------------------------------------------------- ACVP vectors
# NIST's official FIPS 203 test vectors (same tag liboqs 0.16.0 tests against).
ACVP_URL="https://raw.githubusercontent.com/usnistgov/ACVP-Server/refs/tags/v1.1.0.41/gen-val/json-files"
mkdir -p "$B/acvp"
for f in ML-KEM-keyGen-FIPS203 ML-KEM-encapDecap-FIPS203; do
  if [ ! -s "$B/acvp/$f.json" ]; then
    log "ACVP vectors $f"
    curl -fsSL "$ACVP_URL/$f/internalProjection.json" -o "$B/acvp/$f.json" ||
      python3 -c "import urllib.request,sys; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" \
        "$ACVP_URL/$f/internalProjection.json" "$B/acvp/$f.json"
  fi
done

# ---------------------------------------------------------------- summary
log "Done ($ARCH). Optimised implementations in liboqs-opt:"
grep -hE '^#define OQS_ENABLE_KEM_[a-z0-9_]+_(avx2|x86_64|aarch64) '  \
  "$B/liboqs-opt/include/oqs/oqsconfig.h" | sort -u || echo "  (none: portable C only)"
