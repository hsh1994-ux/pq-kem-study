#!/usr/bin/env bash
# Build the KyberSlash control for E3: pq-crystals Kyber768 reference code
# before (old) and after (fixed) the KyberSlash patches, each at -O0, -Os,
# -O2 and -O3, linked into bin/dudect-kyber-<variant>-<opt>.
# Object files are kept in $BUILD_DIR/kyber-<variant>-<opt>/ so run_e3.py can
# scan them for DIV instructions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/versions.env"
B="${BUILD_DIR:-$ROOT/build}"
CC="${CC:-cc}"
SRCS="cbd.c fips202.c indcpa.c kem.c ntt.c poly.c polyvec.c reduce.c symmetric-shake.c verify.c"
OPTS="${KYBER_OPTS:-O0 Os O2 O3}"
mkdir -p "$B/src" "$ROOT/bin"

for variant in old fixed; do
  if [ "$variant" = old ]; then commit=$KYBER_OLD_COMMIT; else commit=$KYBER_FIXED_COMMIT; fi
  src="$B/src/kyber-$variant"
  if [ ! -d "$src/.git" ]; then
    rm -rf "$src.part"
    git clone -q https://github.com/pq-crystals/kyber "$src.part"
    git -C "$src.part" checkout -q "$commit"
    mv "$src.part" "$src"
  fi
  for opt in $OPTS; do
    obj="$B/kyber-$variant-$opt"
    exe="$ROOT/bin/dudect-kyber-$variant-$opt"
    [ -x "$exe" ] && continue
    mkdir -p "$obj"
    for s in $SRCS; do
      "$CC" -"$opt" -DKYBER_K=3 -I"$src/ref" -c "$src/ref/$s" -o "$obj/${s%.c}.o"
    done
    # randombytes() comes from dudect, so Kyber's randombytes.c is not linked.
    "$CC" -O2 -std=c11 -D_GNU_SOURCE -DKYBER_K=3 -DKYBER_VARIANT="\"$variant-$opt\"" \
      -I"$src/ref" "$ROOT/ct/dudect_kyber.c" "$obj"/*.o -lm -o "$exe"
    echo "built $(basename "$exe")"
  done
done
