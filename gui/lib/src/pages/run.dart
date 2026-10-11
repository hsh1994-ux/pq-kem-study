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

  Widget _field(String label, TextEditingController c, {String? hint, double width = 180}) {
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
          const Divider(height: 24),
          Text('Options', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text('Leave a box empty to use the default. Values apply to the experiments listed under each name.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          _OptionRow(
            name: 'Quick smoke test',
            variable: 'QUICK=1',
            usedBy: 'all',
            input: Row(mainAxisSize: MainAxisSize.min, children: [
              Switch(value: _quick, onChanged: busy ? null : (v) => setState(() => _quick = v)),
              Text(_quick ? 'on' : 'off'),
            ]),
            help: 'Runs every experiment with very few iterations, only to check that everything works '
                '(all four in ~10 min). Files are saved with a _quick suffix and are not used for the report; '
                'the viewer hides them unless you tick "show quick runs". Leave off for real measurements.',
          ),
          _OptionRow(
            name: 'Cooldown',
            variable: 'COOLDOWN',
            usedBy: 'E1',
            input: _field('seconds', _cooldown, hint: '0'),
            help: 'Pause between KEMs in E1. A fanless laptop (MacBook Air) heats up during long benchmarks and '
                'lowers its clock speed, which would make later KEMs look slower than they are; the pause lets it '
                'cool down. 30 s is a good value on laptops; it adds about 15 min (29 pauses). Default 0.',
          ),
          _OptionRow(
            name: 'Timed calls per operation',
            variable: 'N_OPS',
            usedBy: 'E1',
            input: _field('calls', _nOps, hint: '1000'),
            help: 'How many times each keygen, encaps and decaps is timed. The median of these is the number in '
                'the results; more calls give a steadier median but take longer. Default 1000 (50 in quick mode).',
          ),
          _OptionRow(
            name: 'McEliece key generations',
            variable: 'N_MCE_KEYGEN',
            usedBy: 'E1',
            input: _field('keygens', _nMce, hint: '20'),
            help: 'Classic McEliece key generation is slow (30–500 ms each) and varies a lot, because it retries '
                'until a random matrix works, so it gets its own count. 20 is enough for a rough median; 100 '
                'gives a more reliable one (a few extra minutes). Default 20 (2 in quick mode).',
          ),
          _OptionRow(
            name: 'dudect time per target',
            variable: 'DUDECT_SECONDS',
            usedBy: 'E3',
            input: _field('seconds', _dudect, hint: '60'),
            help: 'How long dudect measures each target (controls, each KEM in each build, each Kyber variant: '
                'about 22 targets, plus re-runs of anything flagged). Longer runs can detect smaller timing '
                'differences. Default 60 s, i.e. ~25 min for E3 (5 s in quick mode).',
          ),
          _OptionRow(
            name: 'Only these KEMs',
            variable: 'KEMS, E3_KEMS',
            usedBy: 'E1, E3, E4',
            input: _field('names', _kems, hint: 'ML-KEM-768,HQC-1', width: 220),
            help: 'Comma-separated liboqs names to test only some KEMs, e.g. to repeat one measurement. Empty = '
                'all 12 KEMs in kems.conf (E3 defaults to the level-1 KEMs plus all ML-KEM sizes). Names: '
                'ML-KEM-512/768/1024, HQC-1/3/5, FrodoKEM-640/976/1344-SHAKE, Classic-McEliece-348864/460896/6688128.',
          ),
          _OptionRow(
            name: 'Other variables',
            variable: 'KEY=VALUE …',
            usedBy: 'any',
            input: _field('KEY=VALUE', _extra, hint: 'PIN_CPU=2', width: 220),
            help: 'Anything else the scripts read, separated by spaces (no spaces inside a value). '
                'Click one below to add it with its default value, then edit it.',
            extra: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final v in _moreVars)
                Tooltip(
                  message: '${v.help}\nDefault: ${v.example.split('=').last}',
                  child: ActionChip(
                    label: Text('${v.example.split('=').first} · ${v.usedBy}'),
                    onPressed: busy
                        ? null
                        : () => setState(() {
                              final key = v.example.split('=').first;
                              final cur = parseEnvText(_extra.text);
                              if (!cur.containsKey(key)) {
                                _extra.text = [_extra.text.trim(), v.example].where((x) => x.isNotEmpty).join(' ');
                              }
                            }),
                  ),
                ),
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

class _Var {
  const _Var(this.example, this.usedBy, this.help);
  final String example;
  final String usedBy;
  final String help;
}

const _moreVars = [
  _Var('PIN_CPU=1', 'E1', 'Which CPU core E1 runs on (pinned with taskset so the OS does not move it between cores). '
      'Empty disables pinning.'),
  _Var('WARMUP_MS=200', 'E1', 'Busy-wait before the first timed call so the core is at full clock speed '
      '(the M4 needs ~90 ms to ramp up after idle).'),
  _Var('N_HS=200', 'E2', 'TLS handshakes per group and network setting (10 in quick mode).'),
  _Var('RTTS=0,50,200', 'E2', 'Round-trip delays to emulate, in ms (tc netem).'),
  _Var('LOSSES=0,1,3', 'E2', 'Packet-loss rates to emulate, in percent.'),
  _Var('E2_GROUPS=x25519,X25519MLKEM768,MLKEM768', 'E2', 'TLS key-exchange groups to test (default: all of them).'),
  _Var('MTU=1500', 'E2', 'Packet size limit on the emulated link; 1500 is normal Ethernet.'),
];

/// One option: name, variable, which experiments use it, input, explanation.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.name,
    required this.variable,
    required this.usedBy,
    required this.input,
    required this.help,
    this.extra,
  });

  final String name;
  final String variable;
  final String usedBy;
  final Widget input;
  final String help;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(name, style: theme.textTheme.labelLarge),
      const SizedBox(height: 2),
      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(variable, style: small?.copyWith(fontFamily: 'monospace')),
        Pill(usedBy, theme.colorScheme.primary),
      ]),
    ]);
    final explanation = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(help, style: small),
      if (extra != null) Padding(padding: const EdgeInsets.only(top: 6), child: extra),
    ]);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 760) {
          // Narrow window: name and input on one line, explanation below.
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SizedBox(width: 220, child: title),
              input,
            ]),
            const SizedBox(height: 6),
            explanation,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 220, child: title),
          const SizedBox(width: 12),
          SizedBox(width: 240, child: Align(alignment: Alignment.centerLeft, child: input)),
          const SizedBox(width: 16),
          Expanded(child: explanation),
        ]);
      }),
    );
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
