# Results viewer (Flutter desktop app)

A desktop app that shows everything the study writes to `results/raw/`. It runs on macOS, Windows
and Linux, on Apple silicon, ARM64 and x86-64.

| Page | What it shows |
| --- | --- |
| Overview | One card per machine: CPU, VM/container, compiler, versions, runs, E4 status, headline numbers |
| Performance | E1 keygen/encaps/decaps per KEM, with any runs and builds (ref / opt / OpenSSL) side by side. Time, estimated core cycles or raw ticks; log or linear; IQR whiskers; filter by security level |
| Compare | Ratio B/A for every KEM and operation: opt vs ref speed-up, run-to-run repeatability, machine vs machine, with a ±tolerance highlight |
| Sizes | Public key, secret key, ciphertext and shared-secret sizes, and whether a public key fits a TLS key share |
| TLS | E2 handshake time and bytes per group, for each RTT/loss setting |
| Timing | E3 dudect results with a planted-leak control check, the KyberSlash DIV scan, and Valgrind |
| Correctness | E4 KAT / ACVP / cross-check results |
| Files | Every CSV with its machine metadata and raw rows |

- Every table has a copy button that copies tab-separated text, which pastes into Excel, Numbers or
  a LaTeX table generator.
- Every chart has a "Save chart as PNG" button, which writes to `figures/gui/`.
- The app reloads by itself when a new results file appears.

It uses only Flutter and `dart:io`, with no plugins, CocoaPods or other packages. That is why it
builds the same way everywhere.

## First time on a machine

You need Flutter (3.10 or newer) with desktop support:
[install Flutter](https://docs.flutter.dev/get-started/install).

- On macOS you also need Xcode.
- On Windows you also need Visual Studio 2022 with the "Desktop development with C++" workload.
- On Linux you also need `clang cmake ninja-build pkg-config libgtk-3-dev`.

Generate the platform folders once:

```sh
cd gui
./setup.sh          # macOS / Linux
# .\setup.ps1       # Windows PowerShell
```

`setup.sh` runs `flutter create` for macOS, Windows and Linux. It keeps the existing `lib/` and
`pubspec.yaml`, and switches off the macOS app sandbox, which would otherwise stop the app from
reading `results/raw`. If you commit the generated `macos/`, `windows/` and `linux/` folders, other
machines can skip this step.

## Running

```sh
cd gui
flutter run -d macos      # or: -d windows, -d linux
flutter build macos       # a standalone app in build/macos/Build/Products/Release/
```

`make gui` in the repository root does the same on macOS and Linux.

The app finds `../results/raw` by itself when it is started from inside the repository. Otherwise,
choose the folder with the folder button: paste the path to `results/raw`, or to the repository
root. It remembers the last folder.

- **macOS:** the repo is on the Desktop, so the first launch may ask for permission to access the
  Desktop folder. Click Allow. To copy a folder's path in Finder, select it and press
  Option-Command-C.
- **Windows with the results in WSL2:**
  - Either `git pull` the results into a Windows clone,
  - or open `\\wsl.localhost\Ubuntu-24.04\home\<you>\pq-kem-study\results\raw` directly. Automatic
    reload may not fire on that network path; use the reload button.
  - Alternatively, build and run the Linux version inside WSL2 (Windows 11 shows Linux windows
    through WSLg): `./setup.sh && flutter run -d linux`.

## Tests

```sh
cd gui
flutter test      # CSV parsing, formatting, and every page laid out with the real results files
```

## Notes on the numbers

- **Core cycles (est.)** = median time × the core clock that `bench_kem` estimated just before and
  after each timed loop. The estimate times a chain of dependent additions, each taking one cycle.
  Use it to compare with papers, which report cycles with turbo off. It exists only in runs made
  after the calibration update; re-run `make bench` for older data.
- **Timer ticks** are TSC ticks on x86-64 and 24 MHz counter ticks on ARM64. Do not compare them
  across machines.
- Runs whose name ends in `_quick` are smoke tests. They are hidden unless you tick "show quick
  runs".
