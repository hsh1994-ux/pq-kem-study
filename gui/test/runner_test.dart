// Command lines the Run page builds (no processes are started here).
import 'package:flutter_test/flutter_test.dart';
import 'package:pq_results/src/runner.dart';

void main() {
  test('shell quoting', () {
    expect(sq("it's"), r"'it'\''s'");
    expect(sq('a b'), "'a b'");
  });

  test('environment text', () {
    expect(parseEnvText(' PIN_CPU=2  WARMUP_MS=300 junk =x 1A=2'), {'PIN_CPU': '2', 'WARMUP_MS': '300'});
  });

  test('WSL paths', () {
    expect(wslFromUnc(r'\\wsl.localhost\Ubuntu-24.04\home\hsh\pq-kem-study'), ('Ubuntu-24.04', '/home/hsh/pq-kem-study'));
    expect(wslFromUnc(r'\\wsl$\Ubuntu\home\x'), ('Ubuntu', '/home/x'));
    expect(wslFromUnc(r'C:\Users\x'), isNull);
    expect(winToWsl(r'C:\Users\Hamdan\pq-kem-study'), '/mnt/c/Users/Hamdan/pq-kem-study');
  });

  test('docker plan mounts the repository and passes variables', () {
    final c = RunConfig(mode: RunMode.docker, repoRoot: '/Users/h/lab 1/pq-kem-study', cpuLabel: 'Apple M4');
    final p = planMake(c, ['kat', 'bench'], {'COOLDOWN': '30'}, containerName: 'n1');
    expect(p.args.first, 'run');
    expect(p.args, containsAllInOrder(['--name', 'n1']));
    expect(p.args, containsAllInOrder(['-e', 'CPU_MODEL=Apple M4']));
    expect(p.args, containsAllInOrder(['-e', 'COOLDOWN=30']));
    expect(p.args, containsAllInOrder(['-v', '/Users/h/lab 1/pq-kem-study:/work', 'pq-kem-study', 'make', 'kat', 'bench']));
    expect(p.container, 'n1');
  });

  test('wsl and native plans run make in its own process group', () {
    final w = RunConfig(mode: RunMode.wsl, repoRoot: r'\\wsl.localhost\U\home\h\r', wslDistro: 'U', wslPath: '/home/h/r');
    final pw = planMake(w, ['bench'], {'N_OPS': '10'});
    expect(pw.exe, 'wsl.exe');
    expect(pw.args.sublist(0, 5), ['-d', 'U', '-e', 'bash', '-c']);
    expect(pw.args.last, contains("cd '/home/h/r' || exit 1;"));
    expect(pw.args.last, contains("N_OPS='10' setsid make bench &"));
    final n = RunConfig(mode: RunMode.native, repoRoot: '/home/h/r');
    final pn = planMake(n, ['quick'], {});
    expect(pn.exe, 'bash');
    expect(pn.cwd, '/home/h/r');
    expect(pn.args.last, contains('setsid make quick &'));
  });
}
