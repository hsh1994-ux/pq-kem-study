// Running the experiments from the app.
//
// The study itself needs Linux (network namespaces, /proc, Valgrind), so:
//   macOS   -> inside the Docker image (docker/Dockerfile), like the README
//   Windows -> inside WSL2 (wsl.exe), where the repository was cloned
//   Linux   -> `make` directly (or Docker)
// Every mode runs `make <targets>` with the chosen environment variables and
// streams stdout/stderr into the app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum RunMode { docker, wsl, native }

const runModeLabels = {
  RunMode.docker: 'Docker',
  RunMode.wsl: 'WSL2',
  RunMode.native: 'This machine (make)',
};

/// Modes that make sense on the current OS, best first.
List<RunMode> availableModes() {
  if (Platform.isMacOS) return const [RunMode.docker];
  if (Platform.isWindows) return const [RunMode.wsl, RunMode.docker];
  return const [RunMode.native, RunMode.docker];
}

/// Single-quote for bash.
String sq(String s) => "'${s.replaceAll("'", r"'\''")}'";

final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// "A=1 B='x y'" style text -> map (simple split on whitespace; no spaces in values).
Map<String, String> parseEnvText(String text) {
  final out = <String, String>{};
  for (final tok in text.split(RegExp(r'\s+'))) {
    final eq = tok.indexOf('=');
    if (eq <= 0) continue;
    final k = tok.substring(0, eq);
    if (_envName.hasMatch(k)) out[k] = tok.substring(eq + 1);
  }
  return out;
}

/// \\wsl.localhost\Ubuntu-24.04\home\me\repo -> (Ubuntu-24.04, /home/me/repo)
(String, String)? wslFromUnc(String p) {
  final m = RegExp(r'^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(\\.*)?$', caseSensitive: false).firstMatch(p);
  if (m == null) return null;
  final rest = (m.group(2) ?? '').replaceAll(r'\', '/');
  return (m.group(1)!, rest.isEmpty ? '/' : rest);
}

/// C:\Users\me\repo -> /mnt/c/Users/me/repo
String winToWsl(String p) {
  final m = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(p);
  if (m == null) return p.replaceAll(r'\', '/');
  return '/mnt/${m.group(1)!.toLowerCase()}/${m.group(2)!.replaceAll(r'\', '/')}';
}

/// The chip name for CPU_MODEL inside Docker on a Mac (Linux there cannot see it).
String hostCpuLabel() {
  try {
    if (Platform.isMacOS) {
      final r = Process.runSync('sysctl', ['-n', 'machdep.cpu.brand_string']);
      final s = '${r.stdout}'.trim();
      if (s.isNotEmpty) return s;
    }
  } catch (_) {}
  return '';
}

/// Docker CLI: apps started from Finder get a minimal PATH, so look in the
/// usual install locations too.
String dockerExe() {
  final home = Platform.environment['HOME'] ?? '';
  final cands = [
    '/usr/local/bin/docker',
    '/opt/homebrew/bin/docker',
    '$home/.docker/bin/docker',
    '/Applications/Docker.app/Contents/Resources/bin/docker',
    '/usr/bin/docker',
  ];
  if (!Platform.isWindows) {
    for (final c in cands) {
      if (File(c).existsSync()) return c;
    }
  }
  return 'docker';
}

/// PATH with the usual tool locations added (Docker's credential helpers must be found too).
Map<String, String> toolEnv() {
  final env = Map<String, String>.from(Platform.environment);
  if (!Platform.isWindows) {
    final home = env['HOME'] ?? '';
    final extra = [
      '/usr/local/bin', '/opt/homebrew/bin', '$home/.docker/bin', //
      '/Applications/Docker.app/Contents/Resources/bin',
    ];
    env['PATH'] = [...extra, env['PATH'] ?? '/usr/bin:/bin'].join(':');
  }
  env['PYTHONUNBUFFERED'] = '1';
  return env;
}

class RunConfig {
  RunConfig({
    required this.mode,
    required this.repoRoot,
    this.image = 'pq-kem-study',
    this.cpuLabel = '',
    this.wslDistro = '',
    this.wslPath = '',
  });

  RunMode mode;
  String repoRoot;
  String image;
  String cpuLabel;
  String wslDistro;
  String wslPath;

  /// Defaults for this OS and repository location.
  factory RunConfig.defaults(String repoRoot) {
    final modes = availableModes();
    var distro = '', path = '';
    if (Platform.isWindows) {
      final u = wslFromUnc(repoRoot);
      if (u != null) {
        distro = u.$1;
        path = u.$2;
      } else {
        path = winToWsl(repoRoot);
      }
    }
    return RunConfig(mode: modes.first, repoRoot: repoRoot, cpuLabel: hostCpuLabel(), wslDistro: distro, wslPath: path);
  }
}

/// A concrete command line.
class RunPlan {
  const RunPlan(this.exe, this.args, {this.cwd, this.container, this.display = ''});
  final String exe;
  final List<String> args;
  final String? cwd;

  /// Docker container name, for stopping.
  final String? container;

  /// What to show the user (copy-pasteable).
  final String display;
}

const pidFile = '/tmp/pq-kem-gui-run.pid';

/// `make <targets>` with [env], in the configured mode.
RunPlan planMake(RunConfig c, List<String> targets, Map<String, String> env, {String? containerName}) {
  final envPart = env.entries.map((e) => '${e.key}=${sq(e.value)}').join(' ');
  final make = 'make ${targets.join(' ')}';
  if (c.mode == RunMode.docker) {
      final name = containerName ?? 'pq-kem-gui-${DateTime.now().millisecondsSinceEpoch}';
      final args = [
        'run', '--rm', '--init', '--name', name, '--cap-add=NET_ADMIN', //
        '-e', 'PYTHONUNBUFFERED=1',
        if (c.cpuLabel.isNotEmpty) ...['-e', 'CPU_MODEL=${c.cpuLabel}'],
        for (final e in env.entries) ...['-e', '${e.key}=${e.value}'],
        '-v', '${c.repoRoot}:/work',
        c.image,
        ...['make', ...targets],
      ];
      return RunPlan(dockerExe(), args,
          cwd: c.repoRoot,
          container: name,
          display: 'docker run --rm --cap-add=NET_ADMIN'
              '${c.cpuLabel.isNotEmpty ? ' -e CPU_MODEL="${c.cpuLabel}"' : ''}'
              '${env.entries.map((e) => ' -e ${e.key}=${e.value}').join()}'
              ' -v "${c.repoRoot}":/work ${c.image} $make');
  }
  if (c.mode == RunMode.wsl) {
      // setsid puts make in its own process group so Stop can end all of it.
      final script = 'cd ${sq(c.wslPath)} || exit 1; '
          'env PYTHONUNBUFFERED=1 $envPart setsid $make & p=\$!; echo \$p > $pidFile; wait \$p';
      return RunPlan('wsl.exe', [if (c.wslDistro.isNotEmpty) ...['-d', c.wslDistro], '-e', 'bash', '-c', script],
          display: 'wsl${c.wslDistro.isNotEmpty ? ' -d ${c.wslDistro}' : ''}: cd ${c.wslPath} && '
              '${envPart.isEmpty ? '' : '$envPart '}$make');
  }
  final script = 'env PYTHONUNBUFFERED=1 $envPart setsid $make & p=\$!; echo \$p > $pidFile; wait \$p';
  return RunPlan('bash', ['-c', script],
      cwd: c.repoRoot, display: 'cd ${c.repoRoot} && ${envPart.isEmpty ? '' : '$envPart '}$make');
}

RunPlan planDockerBuild(RunConfig c) => RunPlan(
      dockerExe(),
      ['build', '-t', c.image, '-f', 'docker/Dockerfile', '.'],
      cwd: c.repoRoot,
      display: 'docker build -t ${c.image} -f docker/Dockerfile .',
    );

RunPlan planDockerCheck(RunConfig c) => RunPlan(
      dockerExe(),
      ['image', 'inspect', '--format', 'image {{.RepoTags}} {{.Architecture}}, created {{.Created}}', c.image],
      display: 'docker image inspect ${c.image}',
    );

/// Runs one plan at a time and keeps its output.
class Runner extends ChangeNotifier {
  static const maxLines = 20000;

  final lines = <String>[];
  Process? _proc;
  RunPlan? _plan;
  RunMode? _mode;
  String? _wslDistro;
  String? label;
  DateTime? started;
  DateTime? finished;
  int? exitCode;
  bool stopping = false;

  /// Called after every run (e.g. to reload the results).
  VoidCallback? onFinished;

  bool get running => _proc != null;
  RunPlan? get plan => _plan;

  Duration get elapsed => started == null ? Duration.zero : (finished ?? DateTime.now()).difference(started!);

  void _add(String l) {
    lines.add(l);
    if (lines.length > maxLines) lines.removeRange(0, lines.length - maxLines);
  }

  void clear() {
    if (running) return;
    lines.clear();
    notifyListeners();
  }

  Future<void> start(String what, RunPlan p, {RunMode? mode, String? wslDistro}) async {
    if (running) return;
    _plan = p;
    _mode = mode;
    _wslDistro = wslDistro;
    label = what;
    started = DateTime.now();
    finished = null;
    exitCode = null;
    stopping = false;
    _add('');
    _add('━━ $what · ${started!.toLocal().toString().substring(0, 19)}');
    _add('\$ ${p.display}');
    notifyListeners();
    try {
      final proc = await Process.start(p.exe, p.args, workingDirectory: p.cwd, environment: toolEnv());
      _proc = proc;
      notifyListeners();
      final done = Completer<void>();
      var open = 2;
      void pipe(Stream<List<int>> s) {
        s.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(
          (l) {
            _add(l);
            notifyListeners();
          },
          onDone: () {
            if (--open == 0) done.complete();
          },
        );
      }

      pipe(proc.stdout);
      pipe(proc.stderr);
      final code = await proc.exitCode;
      await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      exitCode = code;
      _add('━━ ${stopping ? 'stopped' : 'finished'} with exit code $code after ${_fmt(elapsed)}');
    } catch (e) {
      exitCode = -1;
      _add('!! could not start ${p.exe}: $e');
      if (p.exe.contains('docker')) {
        _add('   Is Docker Desktop installed and running?');
      } else if (p.exe == 'wsl.exe') {
        _add('   Is WSL installed? (wsl --install in an administrator PowerShell)');
      }
    }
    _proc = null;
    finished = DateTime.now();
    notifyListeners();
    onFinished?.call();
  }

  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) return;
    stopping = true;
    _add('━━ stopping…');
    notifyListeners();
    try {
      final c = _plan?.container;
      if (c != null) {
        await Process.run(dockerExe(), ['stop', '-t', '3', c], environment: toolEnv());
      } else if (_mode == RunMode.wsl) {
        await Process.run('wsl.exe', [
          if ((_wslDistro ?? '').isNotEmpty) ...['-d', _wslDistro!],
          '-e', 'bash', '-c', 'kill -TERM -- -\$(cat $pidFile) 2>/dev/null', //
        ]);
      } else if (_mode == RunMode.native) {
        await Process.run('bash', ['-c', 'kill -TERM -- -\$(cat $pidFile) 2>/dev/null']);
      }
    } catch (_) {}
    proc.kill();
  }

  @override
  void dispose() {
    if (running) unawaited(stop());
    super.dispose();
  }
}

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String fmtElapsed(Duration d) => _fmt(d);
