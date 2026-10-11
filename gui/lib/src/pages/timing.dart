// E3: constant-time evidence -- dudect, KyberSlash DIV scan, Valgrind.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../bar_chart.dart';
import '../data.dart';
import '../format.dart';
import '../widgets.dart';

class TimingPage extends StatefulWidget {
  const TimingPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<TimingPage> createState() => _TimingPageState();
}

class _TimingPageState extends State<TimingPage> {
  String? _dudect;
  String? _valgrind;
  String? _divscan;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final dud = repo.of('e3dudect'), val = repo.of('e3valgrind'), div = repo.of('e3divscan');
    if (dud.isEmpty && val.isEmpty && div.isEmpty) {
      return const Center(child: Text('No E3 results yet: run `make ct`.'));
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      if (dud.isNotEmpty) _dudectSection(repo, dud),
      if (div.isNotEmpty) _divSection(repo, div),
      if (val.isNotEmpty) _valgrindSection(repo, val),
    ]);
  }

  Widget _dudectSection(ResultsRepo repo, List<ResultFile> files) {
    final f = repo.byName(_dudect ?? '') ?? files.first;
    final leaky = f.rows.where((r) => r['target'] == 'planted-leaky-memcmp').toList();
    final ctrl = f.rows.where((r) => r['target'] == 'planted-ct-memcmp').toList();
    final controlsOk = leaky.isNotEmpty && leaky.first['verdict'] == 'leak';
    final ctFlagged = ctrl.isNotEmpty && ctrl.first['verdict'] == 'leak';

    final groups = <ChartGroup>[];
    final rows = <List<TCell>>[];
    var i = 0;
    for (final r in f.rows) {
      final t = numOf(r, 'max_t') ?? 0.0;
      final verdict = r['verdict'] ?? '';
      final isFf = (r['op'] ?? '').contains('ff') || (r['target'] ?? '').contains('ff');
      final label = '${r['tier']} · ${r['target']}${isFf ? ' (fixed-vs-fixed)' : ''}';
      groups.add(ChartGroup(label, [
        ChartBar(
          series: 0,
          value: math.max(t, 0.01),
          color: statusColor(verdict),
          tooltip: '$label\nmax |t| = ${sig3(t)}  ($verdict)\n'
              '${groupDigits(numOf(r, 'measurements') ?? 0)} measurements in ${r['seconds']} s'
              '${(r['replicate_max_t'] ?? '').isNotEmpty ? '\nreplicate |t| = ${r['replicate_max_t']}' : ''}',
        ),
      ]));
      final idx = i++;
      rows.add([
        TCell('$idx', sort: idx),
        TCell(r['tier'] ?? ''),
        TCell(r['target'] ?? ''),
        TCell(r['op'] ?? ''),
        TCell(r['opt_level'] ?? ''),
        TCell.number(numOf(r, 'measurements'), groupDigits),
        TCell.number(numOf(r, 'max_t'), sig3),
        TCell.number(numOf(r, 'replicate_max_t'), sig3),
        TCell.number(numOf(r, 'tau'), (v) => v.toStringAsFixed(4)),
        TCell(verdict, widget: Pill(verdict, statusColor(verdict))),
      ]);
    }

    return Section(
      title: 'E3 · dudect (fixed vs random inputs)',
      subtitle: '|t| > 10 counts as a leak; a flagged KEM target is re-run and only reported as a leak if the '
          're-run is flagged too. Colours: green no evidence, amber inconclusive, red leak.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FileDropdown(files: files, value: f, onChanged: (v) => setState(() => _dudect = v?.name)),
        const SizedBox(height: 8),
        Row(children: [
          Icon(controlsOk && !ctFlagged ? Icons.check_circle : Icons.warning_amber,
              color: controlsOk && !ctFlagged ? okGreen : badRed),
          const SizedBox(width: 8),
          Expanded(
            child: Text(controlsOk && !ctFlagged
                ? 'Controls OK: the planted leak was detected (|t| = ${leaky.first['max_t']}) and the '
                    'constant-time control was not flagged, so this machine can detect leaks.'
                : 'Controls failed: the planted leak was ${controlsOk ? '' : 'NOT '}detected'
                    '${ctFlagged ? ' and the constant-time control was flagged' : ''}. '
                    '"No evidence" verdicts from this run are not trustworthy.'),
          ),
        ]),
        const SizedBox(height: 12),
        ExportableChart(
          fileStem: 'e3_dudect',
          outDir: '${repo.repoRoot}${ResultsRepo.sep}figures${ResultsRepo.sep}gui',
          child: HBarChart(
            series: const [ChartSeries('max |t|', Color(0xFF3B6FD8))],
            groups: groups,
            format: sig3,
            labelWidth: 300,
            barHeight: 12,
            threshold: 10,
            thresholdLabel: '|t| = 10',
            axisTitle: 'max |t|',
            showLegend: false,
          ),
        ),
        const SizedBox(height: 12),
        SortableTable(
          columns: const ['#', 'Tier', 'Target', 'Op', 'Opt', 'Measurements', 'max |t|', 'Replicate |t|', 'τ', 'Verdict'],
          numeric: const {0, 5, 6, 7, 8},
          rows: rows,
        ),
      ]),
    );
  }

  Widget _divSection(ResultsRepo repo, List<ResultFile> files) {
    final f = repo.byName(_divscan ?? '') ?? files.first;
    final rows = [
      for (final r in f.rows)
        [
          TCell(r['variant'] ?? ''),
          TCell(r['opt_level'] ?? ''),
          TCell(r['function'] ?? ''),
          TCell(r['div_instructions'] ?? '',
              sort: numOf(r, 'div_instructions'),
              widget: (numOf(r, 'div_instructions') ?? 0) > 0
                  ? Pill('${r['div_instructions']} DIV', badRed)
                  : const Pill('none', okGreen)),
          TCell(r['compiler'] ?? ''),
        ],
    ];
    return Section(
      title: 'KyberSlash · DIV instructions emitted',
      subtitle: 'Static check of pq-crystals Kyber768 (before / after the fix). A real DIV on secret data is '
          'what KyberSlash exploits; whether the compiler emits one depends on the optimisation level.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FileDropdown(files: files, value: f, onChanged: (v) => setState(() => _divscan = v?.name)),
        const SizedBox(height: 8),
        SortableTable(columns: const ['Variant', 'Opt', 'Function', 'DIVs', 'Compiler'], numeric: const {3}, rows: rows),
      ]),
    );
  }

  Widget _valgrindSection(ResultsRepo repo, List<ResultFile> files) {
    final f = repo.byName(_valgrind ?? '') ?? files.first;
    final rows = [
      for (final r in f.rows)
        [
          TCell(r['alg'] ?? '', sort: repo.catalog.order.indexOf(r['alg'] ?? '')),
          TCell.number(numOf(r, 'contexts_raw'), groupDigits),
          TCell.number(numOf(r, 'errors_raw'), groupDigits),
          TCell(r['errors_after_upstream_suppressions'] ?? '',
              sort: numOf(r, 'errors_after_upstream_suppressions'),
              widget: Pill(r['errors_after_upstream_suppressions'] ?? '?',
                  (numOf(r, 'errors_after_upstream_suppressions') ?? 1) == 0 ? okGreen : badRed)),
          TCell(r['upstream_known_issue'] ?? ''),
          TCell(r['valgrind_crashed'] ?? ''),
          TCell((r['functions'] ?? '').replaceAll(';', ', ')),
        ],
    ];
    return Section(
      title: 'Valgrind · secret-dependent branches and memory accesses',
      subtitle: 'liboqs ct build, all random bytes marked secret. "After suppressions" applies liboqs\' own '
          'list of known, reviewed issues.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FileDropdown(files: files, value: f, onChanged: (v) => setState(() => _valgrind = v?.name)),
        const SizedBox(height: 8),
        SortableTable(
          columns: const ['KEM', 'Contexts (raw)', 'Errors (raw)', 'After suppressions', 'Known upstream', 'Crashed', 'Functions'],
          numeric: const {1, 2, 3},
          rows: rows,
        ),
      ]),
    );
  }
}
