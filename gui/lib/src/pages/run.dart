// Run the experiments (make kat / bench / tls / ct / figures) from the app
// and watch their output. Results pages refresh when a run finishes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data.dart';
import '../runner.dart';
import '../widgets.dart';

class _Target {
  const _Target(this.make, this.label, this.time, this.note);
  final String make;
  final String label;
  final String time;
  final String note;
}

const _targets = [
  _Target('kat', 'E4 correctness', '~2 min', 'KATs, NIST ACVP vectors, ref/opt and liboqs/OpenSSL cross-checks'),
  _Target('bench', 'E1 performance', '~30–60 min', 'keygen/encaps/decaps timing, sizes, stack; set a cooldown on laptops'),
  _Target('tls', 'E2 TLS', '~10–20 min', 'TLS 1.3 handshakes under emulated delay and loss'),
  _Target('ct', 'E3 constant time', '~30–40 min', 'dudect with controls, KyberSlash DIV scan, Valgrind'),
  _Target('figures', 'Figures', '~1 min', 'figures/*.pdf and report/tables/*.tex from the newest results'),
];

class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.repo, required this.runner});
  final ResultsRepo repo;
  final Runner runner;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  late RunConfig _cfg;
  final Set<String> _selected = {'kat'};
  bool _quick = false;
  final _cooldown = TextEditingController(text: '30');
  final _nOps = TextEditingController();
  final _nMce = TextEditingController();
  final _kems = TextEditingController();
  final _dudect = TextEditingController();
  final _extra = TextEditingController();
  final _image = TextEditingController();
  final _cpu = TextEditingController();
  final _distro = TextEditingController();
  final _wslPath = TextEditingController();
  final _scroll = ScrollController();
  Timer? _tick;
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _cfg = RunConfig.defaults(widget.repo.repoRoot);
    _image.text = _cfg.image;
    _cpu.text = _cfg.cpuLabel;
    _distro.text = _cfg.wslDistro;
    _wslPath.text = _cfg.wslPath;
    widget.runner.addListener(_onRunner);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _follow = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    });
  }

  @override
  void didUpdateWidget(RunPage old) {
    super.didUpdateWidget(old);
    if (old.runner != widget.runner) {
      old.runner.removeListener(_onRunner);
      widget.runner.addListener(_onRunner);
    }
    if (old.repo.repoRoot != widget.repo.repoRoot) {
      final d = RunConfig.defaults(widget.repo.repoRoot);
      _cfg.repoRoot = d.repoRoot;
      if (d.wslPath.isNotEmpty) _wslPath.text = d.wslPath;
      if (d.wslDistro.isNotEmpty) _distro.text = d.wslDistro;
    }
  }

  @override
  void dispose() {
    widget.runner.removeListener(_onRunner);
    _tick?.cancel();
    for (final c in [_cooldown, _nOps, _nMce, _kems, _dudect, _extra, _image, _cpu, _distro, _wslPath]) {
      c.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _onRunner() {
    if (!mounted) return;
    final r = widget.runner;
    if (r.running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!r.running && _tick != null) {
      _tick?.cancel();
      _tick = null;
    }
    setState(() {});
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  RunConfig _currentCfg() {
    _cfg.image = _image.text.trim().isEmpty ? 'pq-kem-study' : _image.text.trim();
    _cfg.cpuLabel = _cpu.text.trim();
    _cfg.wslDistro = _distro.text.trim();
    _cfg.wslPath = _wslPath.text.trim();
    return _cfg;
  }

  Map<String, String> _env() {
    final env = <String, String>{};
    if (_quick) env['QUICK'] = '1';
    void put(String k, TextEditingController c) {
      final v = c.text.trim();
      if (v.isNotEmpty) env[k] = v.replaceAll(' ', '');
    }

    put('COOLDOWN', _cooldown);
    put('N_OPS', _nOps);
    put('N_MCE_KEYGEN', _nMce);
    put('KEMS', _kems);
    put('E3_KEMS', _kems);
    put('DUDECT_SECONDS', _dudect);
    env.addAll(parseEnvText(_extra.text));
    return env;
  }

  void _run(List<String> targets, String what) {
    final cfg = _currentCfg();
    final plan = planMake(cfg, targets, _env());
    _follow = true;
    unawaited(widget.runner.start(what, plan, mode: cfg.mode, wslDistro: cfg.wslDistro));
  }

  Widget _field(String label, TextEditingController c, {String? hint, double width = 150}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        enabled: !widget.runner.running,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.runner;
    final theme = Theme.of(context);
    final busy = r.running;
    final modes = availableModes();
    final ordered = _targets.where((t) => _selected.contains(t.make)).map((t) => t.make).toList();
    final preview = planMake(_currentCfg(), ordered.isEmpty ? ['help'] : ordered, _env(), containerName: 'NAME');
    final tail = r.lines.length > 60 ? r.lines.sublist(r.lines.length - 60) : r.lines;
    final hint = _hintFor(tail.join('\n'));

    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Section(
        title: 'Run experiments',
        subtitle: 'Runs make in ${runModeLabels[_cfg.mode]} on ${_cfg.repoRoot}. New results appear in the other '
            'pages when a run finishes.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (modes.length > 1)
            ControlRow(
              'Run in',
              SegmentedButton<RunMode>(
                segments: [for (final m in modes) ButtonSegment(value: m, label: Text(runModeLabels[m]!))],
                selected: {_cfg.mode},
                onSelectionChanged: busy ? null : (s) => setState(() => _cfg.mode = s.first),
              ),
            ),
          if (_cfg.mode == RunMode.docker)
            ControlRow(
              'Docker',
              Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _field('Image', _image, width: 170),
                _field('CPU name for results', _cpu, hint: 'e.g. Apple M4', width: 200),
                OutlinedButton(
                  onPressed: busy ? null : () => unawaited(r.start('Check image', planDockerCheck(_currentCfg()))),
                  child: const Text('Check image'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => unawaited(r.start('Build image', planDockerBuild(_currentCfg()))),
                  child: const Text('Build image (once, ~20 min)'),
                ),
              ]),
            ),
          if (_cfg.mode == RunMode.wsl)
            ControlRow(
              'WSL',
              Wrap(spacing: 12, runSpacing: 8, children: [
                _field('Distribution', _distro, hint: 'default', width: 170),
                _field('Repository path in Linux', _wslPath, hint: '/home/you/pq-kem-study', width: 320),
              ]),
            ),
          const Divider(height: 24),
          ControlRow(
            'Experiments',
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in _targets)
                Tooltip(
                  message: '${t.note}\nmake ${t.make} · ${t.time}',
                  child: FilterChip(
                    label: Text('${t.label}  (${t.time})'),
                    selected: _selected.contains(t.make),
                    onSelected: busy
                        ? null
                        : (on) => setState(() => on ? _selected.add(t.make) : _selected.remove(t.make)),
                  ),
                ),
            ]),
          ),
          ControlRow(
            'Options',
            Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(value: _quick, onChanged: busy ? null : (v) => setState(() => _quick = v)),
                const Text('Quick smoke test'),
              ]),
              _field('Cooldown (s)', _cooldown, hint: '0', width: 120),
              _field('N_OPS', _nOps, hint: '1000', width: 110),
              _field('McEliece keygens', _nMce, hint: '20', width: 150),
              _field('dudect seconds', _dudect, hint: '60', width: 140),
              _field('Only these KEMs', _kems, hint: 'ML-KEM-768,HQC-1', width: 240),
              _field('Other variables', _extra, hint: 'PIN_CPU=2 WARMUP_MS=300', width: 260),
            ]),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilledButton.icon(
              onPressed: busy || ordered.isEmpty ? null : () => _run(ordered, ordered.map((t) => 'make $t').join(', ')),
              icon: const Icon(Icons.play_arrow),
              label: Text(ordered.isEmpty ? 'Select an experiment' : 'Run ${ordered.join(' + ')}'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => _run(['quick'], 'make quick (smoke test of everything)'),
              child: const Text('Smoke test all (~10 min)'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => _run(['all'], 'make all (full study)'),
              child: const Text('Full study (~1–2 h)'),
            ),
            if (busy)
              FilledButton.tonalIcon(
                onPressed: r.stopping ? null : () => unawaited(r.stop()),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
          ]),
          const SizedBox(height: 8),
          Text('Command: ${preview.display}',
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      Section(
        title: busy ? 'Running: ${r.label}' : (r.label == null ? 'Output' : 'Last run: ${r.label}'),
        subtitle: r.started == null
            ? 'Nothing run yet in this session.'
            : '${busy ? 'elapsed' : 'took'} ${fmtElapsed(r.elapsed)}'
                '${r.exitCode == null ? '' : r.exitCode == 0 ? ' · finished OK' : ' · exit code ${r.exitCode}'}',
        actions: [
          if (busy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          if (!busy && r.exitCode != null)
            Pill(r.exitCode == 0 ? 'OK' : (r.stopping ? 'stopped' : 'failed'), r.exitCode == 0 ? okGreen : badRed),
          IconButton(
            tooltip: 'Copy output',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: r.lines.join('\n')));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Output copied')));
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: busy ? null : r.clear,
          ),
        ],
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                const Icon(Icons.lightbulb_outline, color: warnAmber, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(hint)),
              ]),
            ),
          Container(
            height: 420,
            decoration: BoxDecoration(
              color: const Color(0xFF15171C),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(10),
            child: SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                itemCount: r.lines.length,
                itemBuilder: (context, i) {
                  final l = r.lines[i];
                  final color = l.startsWith('━━')
                      ? const Color(0xFF8AB4F8)
                      : (l.startsWith('!!') || l.contains('Error') || l.contains('FAIL'))
                          ? const Color(0xFFFF8A80)
                          : const Color(0xFFE6E6E6);
                  return Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.3, color: color));
                },
              ),
            ),
          ),
        ]),
      ),
    ]);
  }
}

/// A short suggestion for common failures, from the end of the output.
String? _hintFor(String tail) {
  if (tail.contains('Cannot connect to the Docker daemon') || tail.contains('docker daemon is not running')) {
    return 'Docker Desktop is not running: start it, wait for "Engine running", then try again.';
  }
  if (tail.contains('Unable to find image') || tail.contains('No such image') || tail.contains('pull access denied')) {
    return 'The Docker image is missing: click "Build image" first (takes ~20 minutes once).';
  }
  if (tail.contains('could not start wsl.exe') || tail.contains('There is no distribution with the supplied name')) {
    return 'WSL could not start this distribution: check the name with `wsl -l -v` in PowerShell.';
  }
  if (tail.contains('No such file or directory') && tail.contains('cd: ')) {
    return 'The repository path in Linux looks wrong: use the folder where you cloned pq-kem-study inside WSL.';
  }
  if (tail.contains('No rule to make target')) {
    return 'make does not know that target: is the repository path right and up to date (git pull)?';
  }
  if (tail.contains('build/liboqs') && tail.contains('No such file')) {
    return 'The dependencies are not built here yet: run `make deps` once (10–30 min).';
  }
  return null;
}
