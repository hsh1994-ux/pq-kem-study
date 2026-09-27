#!/usr/bin/env bash
# Print machine + toolchain metadata as '# key=value' lines.
# Every results CSV starts with this block (pandas: read_csv(comment='#')).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/versions.env"

cpu_model() {
  local m
  m=$(grep -m1 -E '^(model name|Model|Hardware)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs)
  if [ -z "$m" ] && command -v lscpu >/dev/null; then
    m=$(lscpu | grep -m1 -E 'Model name' | cut -d: -f2- | xargs)
  fi
  [ -z "$m" ] && m="unknown ($(grep -m1 'CPU implementer' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs))"
  echo "$m"
}

virt() {
  if command -v systemd-detect-virt >/dev/null; then systemd-detect-virt 2>/dev/null || true
  elif grep -qi hypervisor /proc/cpuinfo 2>/dev/null; then echo "vm"
  else echo "unknown"; fi
}

cat <<EOF
# date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# host=$(hostname)
# arch=$(uname -m)
# cpu=$(cpu_model)
# cores=$(nproc)
# kernel=$(uname -r)
# virtualisation=$(virt)
# cc=$(${CC:-cc} --version 2>/dev/null | head -1)
# liboqs=$LIBOQS_TAG
# openssl=$OPENSSL_TAG
# oqs_provider=$OQSPROVIDER_TAG
# repo_commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)
EOF
