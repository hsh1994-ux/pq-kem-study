# Comparative Study of Post-Quantum Key-Encapsulation Mechanisms

Cybersecurity Lab 1, ELTE Faculty of Informatics (Department of Computer Algebra), autumn 2026.

This repository compares four post-quantum KEM families — ML-KEM (FIPS 203), HQC, FrodoKEM and
Classic McEliece — against a classical X25519 baseline and the deployed X25519MLKEM768 hybrid,
across portable and CPU-optimised implementations, on both x86-64 and ARM64.

## Status

Work in progress. See `docs/logs/` for the bi-weekly progress logs.

## Quick start

```sh
make deps      # build pinned OpenSSL, liboqs and oqs-provider (10-30 min, once)
make sysinfo   # machine metadata recorded in every results file
```

Pinned versions are in `versions.env`; the KEMs studied are listed in `kems.conf`.
