# Comparative Study of Post-Quantum Key-Encapsulation Mechanisms

Cybersecurity Lab 1, ELTE Faculty of Informatics (Department of Computer Algebra), autumn 2026.
Author: Hamdan Al-Jabri.

The project compares four post-quantum KEM families (ML-KEM (FIPS 203), HQC, FrodoKEM and Classic
McEliece) against the classical X25519 baseline and the deployed X25519MLKEM768 hybrid. It covers
portable and CPU-optimised implementations on **both x86-64 and ARM64**.

| Research question | Experiment | `make` target | Output |
| --- | --- | --- | --- |
| RQ1 Cost: time, sizes, stack | E1 microbenchmarks | `make bench` | `results/raw/e1_*.csv` |
| RQ2 Deployability in TLS 1.3 | E2 handshakes under delay/loss | `make tls` | `results/raw/e2_*.csv` |
| RQ3 Timing side channels | E3 dudect, KyberSlash control, Valgrind | `make ct` | `results/raw/e3*_*.csv` |
| RQ4 Correctness / interop | E4 KATs, NIST ACVP vectors, cross-checks | `make kat` | `results/raw/e4_*.csv` |

`make figures` turns the newest results into `figures/*.pdf` and `report/tables/*.tex`;
`make report` builds `report/main.pdf`.

## Running it

### On Linux (x86-64 or ARM64)

Needs a C compiler, CMake ≥ 3.22 (< 4), Ninja, git, Python 3 with numpy/pandas/matplotlib/scipy,
`iproute2`, and optionally Valgrind and LaTeX.

```sh
make deps      # build pinned OpenSSL, liboqs and oqs-provider into ./build (10-30 min, once)
make quick     # smoke-test every experiment (~10 min); results are *_quick.csv, not for the report
make all       # the full study (~1-2 h); set COOLDOWN=30 on a fanless laptop
make report
```

`BUILD_DIR=/somewhere/else make ...` keeps the ~1.5 GB of dependencies out of the repo folder. This is a
good idea if the repo lives in an iCloud-synced folder such as the macOS Desktop.

### On a Mac (Apple Silicon) with Docker Desktop

The image contains the whole toolchain, including Valgrind:

```sh
docker build -t pq-kem-study -f docker/Dockerfile .
docker run --rm -it --cap-add=NET_ADMIN -v "$PWD":/work pq-kem-study make quick
docker run --rm -it --cap-add=NET_ADMIN -v "$PWD":/work pq-kem-study make all
```

`--cap-add=NET_ADMIN` is only needed by E2 (network emulation). Inside Docker on a Mac, Linux cannot
see the chip's name, so pass it for the results metadata: `-e CPU_MODEL="Apple M4"`. The same image builds natively on
x86-64 Linux, so both architectures run identical code.

### Useful knobs

| Variable | Used by | Meaning |
| --- | --- | --- |
| `QUICK=1` | all | few iterations, smoke test only |
| `KEMS=ML-KEM-768,HQC-1` | E1, E4 | subset of `kems.conf` |
| `N_OPS`, `N_MCE_KEYGEN`, `COOLDOWN`, `PIN_CPU` | E1 | iterations, McEliece keygens, pause between KEMs (s), core to pin |
| `N_HS`, `GROUPS`, `RTTS`, `LOSSES`, `MTU` | E2 | handshakes per cell, TLS groups, RTTs (ms), loss (%), MTU |
| `DUDECT_SECONDS`, `E3_KEMS` | E3 | time budget per dudect target, KEMs to test |

## Layout

```
versions.env          pinned upstream versions (recorded in every results file)
kems.conf             the KEMs studied, in table/plot order
scripts/              build_deps.sh, sysinfo.sh, pqlib.py (shared Python helpers)
common/cpucycles.h    one timer: fenced RDTSC (x86-64), CNTVCT_EL0 (ARM64), clock_gettime (other)
kat/                  E4: kemtool.c + run_e4.py
bench/                E1: bench_kem.c (liboqs), bench_ossl.c (OpenSSL), run_e1.py
tls/                  E2: hs_client.c + run_e2.py
ct/                   E3: dudect harnesses, patched dudect, KyberSlash build, run_e3.py
analysis/             make_figures.py
report/               LaTeX skeleton of the final report (tables/ is generated)
docs/logs/            bi-weekly progress reports
demo/                 mini-conference demo script
docker/               reproducible toolchain image
results/raw/          one CSV per run, each starting with '# key=value' machine metadata
```

## Method notes

- **Two liboqs builds** per machine: `ref` (portable C, AVX2/NEON disabled) and `opt` (tuned to the
  CPU: AVX2 on x86-64, NEON on ARM64). Only ML-KEM, Classic McEliece and FrodoKEM have optimised code
  on x86-64. On ARM64 only ML-KEM does. HQC is portable C everywhere in liboqs 0.16.0.
- **Timing** on ARM64 uses the architectural counter (24 MHz on Apple silicon, ~41.7 ns per tick),
  because the cycle counter is not readable from user space or inside VMs. Results are converted to
  nanoseconds so both architectures share an axis.
- **E2** runs in its own network namespace (`unshare -rn`, no root needed), with loopback MTU set
  to 1500. Classic McEliece has no TLS group: its 261 KB public key cannot fit in a ClientHello key
  share (maximum 65,535 bytes). This is recorded as a result.
- **E3 controls**: a planted early-exit comparison must be flagged by dudect. If it isn't, that
  machine's "no evidence" verdicts are void. Earlier in development, this control exposed a harness
  bug: the compiler removed the timed work as dead code. See the E3 commit message and
  `ct/dudect_run.h`.
- **KyberSlash** needs both a real DIV instruction (only at `-Os` with gcc on x86-64; see
  `e3divscan`) and a divider with data-dependent latency. "No evidence" on a given CPU is a finding
  about that CPU, not proof of safety.
- dudect is vendored in `ct/dudect/` with a small portability patch (`portable.patch`). Upstream is
  public domain (Unlicense).

## Tools and assistance

Code in this repository was written with the help of Claude (Anthropic), an AI assistant, and each
commit carries a `Co-Authored-By` trailer. The experimental design, the interpretation of the results
and the report are the author's. Disclose this as your course requires.

## License

MIT, see `LICENSE`.
