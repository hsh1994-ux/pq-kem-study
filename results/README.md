# Results

Each `raw/*.csv` starts with `# key=value` lines describing the machine, toolchain and repo commit
(read with `pandas.read_csv(path, comment="#")`). `*_quick.csv` smoke tests are never committed.

Results were cleared on 2026-10-11 to start from one consistent set, measured with the calibrated E1
timer (per-run tick calibration, 200 ms warm-up, core-clock estimate). Earlier runs, including the
indicative ones from a shared cloud VM, are still in the git history (commits up to `0c20ee4`).

| Files | Machine | How |
| --- | --- | --- |
| `raw/*_aarch64_*.csv` | MacBook Air M4, Docker Desktop (Linux VM) | `make all` in the Docker image, `CPU_MODEL="Apple M4"`, `COOLDOWN=30` |
| `raw/*_x86_64_*.csv` | Laptop with Intel Core i7-1185G7, WSL2 Ubuntu 24.04 | `make all` with `COOLDOWN=30` |
