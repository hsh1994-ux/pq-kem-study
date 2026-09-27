# Results

Each `raw/*.csv` starts with `# key=value` lines describing the machine, toolchain and repo commit
(read with `pandas.read_csv(path, comment="#")`). `*_quick.csv` smoke tests are never committed.

| Files | Machine | Status |
| --- | --- | --- |
| `raw/*_x86_64_20260927-*.csv` | 2-core shared cloud VM (Intel Xeon, 2.8 GHz; no `tc netem`, so E2 has RTT 0 only) | **Indicative only.** A shared VM is noisy: use these for the x86-64 vs ARM64 comparison and the RQ4/Valgrind results, and treat E1 absolute timings with caution. |
| `raw/*_aarch64_*.csv` | MacBook Air (Apple silicon), Linux VM | Primary results. Add them after `make all`. |
