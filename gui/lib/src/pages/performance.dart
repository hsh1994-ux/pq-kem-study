// E1: keygen / encaps / decaps cost per KEM, any runs and builds side by side.
import 'package:flutter/material.dart';

import '../bar_chart.dart';
import '../data.dart';
import '../e1.dart';
import '../format.dart';
import '../widgets.dart';

class PerformancePage extends StatefulWidget {
  const PerformancePage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<PerformancePage> createState() => _PerformancePageState();
}

class _PerformancePageState extends State<PerformancePage> {
  Set<String> _files = {};
  Set<String> _tiers = {'ref', 'opt', 'openssl'};
  Set<String> _levels = {'0', '1', '3', '5'};
  String _op = 'encaps';
  E1Metric _metric = E1Metric.time;
  bool _log = true;
  bool _showQuick = false;

  @override
  void initState() {
    super.initState();
    _resetFiles();
  }

  @override
  void didUpdateWidget(PerformancePage old) {
    super.didUpdateWidget(old);
    final names = widget.repo.of('e1').map((f) => f.name).toSet();
    _files = _files.where(names.contains).toSet();
    if (_files.isEmpty) _resetFiles();
  }

  void _resetFiles() {
    _files = widget.repo.latestPerMachine('e1').map((f) => f.name).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final all = repo.of('e1', includeQuick: _showQuick);
    if (repo.of('e1').isEmpty) {
      return const Center(child: Text('No E1 results yet: run `make bench`.'));
    }
    final selected = all.where((f) => _files.contains(f.name)).toList()
      ..sort((a, b) {
        final m = a.machineLabel.compareTo(b.machineLabel);
        return m != 0 ? m : (a.time ?? DateTime(0)).compareTo(b.time ?? DateTime(0));
      });

    // Series = run x build.
    final series = <ChartSeries>[];
    final seriesKeys = <(ResultFile, String, E1Index)>[];
    for (var i = 0; i < selected.length; i++) {
      final f = selected[i];
      final idx = E1Index(f);
      final base = runPalette[i % runPalette.length];
      for (final t in e1Tiers) {
        if (!_tiers.contains(t) || !idx.tiers.contains(t)) continue;
        final name = selected.length == 1 ? tierShort(t) : '${f.machineLabel} ${f.timeLabel} · ${tierShort(t)}';
        series.add(ChartSeries(name, tierShade(base, t)));
        seriesKeys.add((f, t, idx));
      }
    }

    final algs = repo.catalog
        .sort(seriesKeys.expand((s) => s.$3.algs))
        .where((a) => _levels.contains('${repo.catalog.levelOf(a)}'))
        .toList();
    final fmt = e1Format(_metric);
    final groups = <ChartGroup>[];
    final tableRows = <List<TCell>>[];
    var missingCycles = false;
    for (final alg in algs) {
      final bars = <ChartBar>[];
      for (var si = 0; si < seriesKeys.length; si++) {
        final (f, tier, idx) = seriesKeys[si];
        final row = idx.get(tier, alg, _op);
        if (row == null) continue;
        final p = e1Point(row, _metric);
        if (p == null) {
          if (_metric == E1Metric.cycles) missingCycles = true;
          continue;
        }
        final ghz0 = numOf(row, 'ghz_before'), ghz1 = numOf(row, 'ghz_after');
        final iqr = (p.lo != null && p.hi != null && p.value > 0) ? (p.hi! - p.lo!) / p.value * 100 : null;
        final stack = numOf(row, 'stack_bytes');
        bars.add(ChartBar(
          series: si,
          value: p.value,
          lo: p.lo,
          hi: p.hi,
          tooltip: [
            '$alg · $_op · ${series[si].name}',
            'median ${fmt(p.value)}'
                '${p.lo != null && p.hi != null ? '  (IQR ${fmt(p.lo!)} – ${fmt(p.hi!)})' : ''}',
            'n = ${row['n']}${ghz0 != null ? ' · core ~${sig3(ghz0)}–${sig3(ghz1 ?? ghz0)} GHz' : ''}',
          ].join('\n'),
        ));
        tableRows.add([
          TCell(alg, sort: algs.indexOf(alg)),
          TCell(f.machineLabel),
          TCell(f.timeLabel),
          TCell(tierShort(tier)),
          TCell.number(p.value, fmt),
          TCell.number(p.lo, fmt),
          TCell.number(p.hi, fmt),
          TCell.number(iqr, (v) => '${v.toStringAsFixed(1)}%'),
          TCell.number(numOf(row, 'n'), (v) => v.toStringAsFixed(0)),
          TCell.number(stack != null && stack >= 0 ? stack : null, (v) => groupDigits(v)),
          TCell.number(ghz0 == null ? null : (ghz0 + (ghz1 ?? ghz0)) / 2, (v) => v.toStringAsFixed(2)),
        ]);
      }
      if (bars.isNotEmpty) groups.add(ChartGroup(alg, bars));
    }

    final metricName = e1MetricLabels[_metric]!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Section(
          title: 'E1 · Performance',
          subtitle: 'Median per call, one bar per run and build. Hover a bar for details.',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ControlRow(
              'Runs',
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final f in all)
                  FilterChip(
                    label: Text(f.label),
                    selected: _files.contains(f.name),
                    onSelected: (on) => setState(() => on ? _files.add(f.name) : _files.remove(f.name)),
                  ),
                TextButton(
                  onPressed: () => setState(_resetFiles),
                  child: const Text('Newest per machine'),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(value: _showQuick, onChanged: (v) => setState(() => _showQuick = v ?? false)),
                  const Text('show quick runs'),
                ]),
              ]),
            ),
            ControlRow(
              'Builds',
              ChipSet(
                options: e1Tiers,
                labels: e1TierLabels,
                selected: _tiers,
                onChanged: (s) => setState(() => _tiers = s),
              ),
            ),
            ControlRow(
              'Security',
              ChipSet(
                options: const ['0', '1', '3', '5'],
                labels: const {'0': 'Baselines', '1': 'Level 1', '3': 'Level 3', '5': 'Level 5'},
                selected: _levels,
                onChanged: (s) => setState(() => _levels = s),
              ),
            ),
            ControlRow(
              'Operation',
              SegmentedButton<String>(
                segments: [for (final o in e1Ops) ButtonSegment(value: o, label: Text(o))],
                selected: {_op},
                onSelectionChanged: (s) => setState(() => _op = s.first),
              ),
            ),
            ControlRow(
              'Metric',
              Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SegmentedButton<E1Metric>(
                  segments: [
                    for (final m in E1Metric.values) ButtonSegment(value: m, label: Text(e1MetricLabels[m]!)),
                  ],
                  selected: {_metric},
                  onSelectionChanged: (s) => setState(() => _metric = s.first),
                ),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Switch(value: _log, onChanged: (v) => setState(() => _log = v)),
                  const Text('log scale'),
                ]),
              ]),
            ),
            if (_metric == E1Metric.ticks)
              const _Note('Timer ticks are machine-specific (TSC on x86-64, 24 MHz counter on ARM64): '
                  'compare ticks only within one machine.'),
            if (_metric == E1Metric.cycles)
              _Note(missingCycles
                  ? 'Some selected runs were made before the calibration update and have no core-clock '
                      'estimate; re-run `make bench` to include them.'
                  : 'Core cycles = median time × core clock estimated around each timed loop. '
                      'Use this to compare with published cycle counts.'),
          ]),
        ),
        Section(
          title: '$metricName of $_op',
          child: ExportableChart(
            fileStem: 'e1_${_op}_${_metric.name}',
            outDir: '${repo.repoRoot}${ResultsRepo.sep}figures${ResultsRepo.sep}gui',
            child: HBarChart(series: series, groups: groups, format: fmt, log: _log, axisTitle: metricName),
          ),
        ),
        Section(
          title: 'Table',
          child: SortableTable(
            columns: const [
              'KEM', 'Machine', 'Run', 'Build', 'Median', 'p25', 'p75', 'IQR', 'n', 'Stack (B)', 'Core GHz', //
            ],
            numeric: const {4, 5, 6, 7, 8, 9, 10},
            rows: tableRows,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
      ]),
    );
  }
}
