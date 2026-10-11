#!/usr/bin/env bash
# Print machine + toolchain metadata as '# key=value' lines.
# Every results CSV starts with this block (pandas: read_csv(comment='#')).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/versions.env"

cpu_model() {
  # CPU_MODEL overrides everything (e.g. CPU_MODEL="Apple M4" inside Docker on a Mac,
  # where Linux cannot see the chip's marketing name).
  if [ -n "${CPU_MODEL:-}" ]; then echo "$CPU_MODEL"; return; fi
  local m=""
  if [ "$(uname -s)" = Darwin ]; then
    m=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  fi
  [ -z "$m" ] && m=$(grep -m1 -E '^(model name|Model|Hardware)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs)
  if { [ -z "$m" ] || [ "$m" = "-" ]; } && command -v lscpu >/dev/null; then
    m=$(lscpu 2>/dev/null | grep -m1 -E 'Model name' | cut -d: -f2- | xargs)
  fi
  if [ -z "$m" ] || [ "$m" = "-" ]; then
    local impl part
    impl=$(grep -m1 'CPU implementer' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    part=$(grep -m1 'CPU part' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    case "$impl" in 0x61) impl="Apple" ;; 0x41) impl="Arm" ;; esac
    m="unknown ARM (implementer ${impl:-?}, part ${part:-?}); set CPU_MODEL to label it"
  fi
  echo "$m"
}

virt() {
  local v=""
  if command -v systemd-detect-virt >/dev/null; then v=$(systemd-detect-virt 2>/dev/null || true); fi
  if [ -z "$v" ] || [ "$v" = none ]; then
    if [ -f /.dockerenv ] || grep -qs docker /proc/1/cgroup; then v="container"; fi
  fi
  case "$(uname -r)" in
    *linuxkit*) v="${v:+$v in }Docker Desktop VM (linuxkit)" ;;
    *orbstack*) v="${v:+$v in }OrbStack VM" ;;
    *microsoft*|*WSL*) v="${v:+$v in }WSL2" ;;
  esac
  if [ -z "$v" ] && grep -qi hypervisor /proc/cpuinfo 2>/dev/null; then v="vm"; fi
  echo "${v:-none detected}"
}

cat <<EOF
# date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# host=$(hostname)
# arch=$(uname -m)
# cpu=$(cpu_model)
# cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
# kernel=$(uname -r)
# virtualisation=$(virt)
# cc=$(${CC:-cc} --version 2>/dev/null | head -1)
# liboqs=$LIBOQS_TAG
# openssl=$OPENSSL_TAG
# oqs_provider=$OQSPROVIDER_TAG
# repo_commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)
EOF
