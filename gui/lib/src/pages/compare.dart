// Compare two (run, build) pairs row by row: run-to-run repeatability on one
// machine, opt vs ref speed-ups, or one machine against another.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data.dart';
import '../e1.dart';
import '../format.dart';
import '../widgets.dart';

class ComparePage extends StatefulWidget {
  const ComparePage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _Side {
  _Side(this.file, this.tier);
  String? file;
  String tier;
}

class _ComparePageState extends State<ComparePage> {
  late _Side _a;
  late _Side _b;
  E1Metric _metric = E1Metric.time;
  double _threshold = 20;
  bool _onlyDifferent = false;

  @override
  void initState() {
    super.initState();
    _preset('opt-vs-ref');
  }

  @override
  void didUpdateWidget(ComparePage old) {
    super.didUpdateWidget(old);
    final names = widget.repo.of('e1').map((f) => f.name).toSet();
    if (!names.contains(_a.file) || !names.contains(_b.file)) _preset('opt-vs-ref');
  }

  void _preset(String p) {
    final files = widget.repo.of('e1');
    final latest = widget.repo.latestPerMachine('e1');
    final first = files.isEmpty ? null : (latest.isNotEmpty ? latest.first.name : files.first.name);
    if (p == 'machines') {
      final x = latest.isNotEmpty ? latest[0].name : first;
      final y = latest.length > 1 ? latest[1].name : first;
      _a = _Side(x, 'opt');
      _b = _Side(y, 'opt');
    } else if (p == 'repeat') {
      // The two newest runs from the same machine (older = A, newer = B).
      String? x = first, y = first;
      final byM = <String, List<ResultFile>>{};
      for (final f in files.where((f) => !f.quick)) {
        byM.putIfAbsent(f.machineKey, () => []).add(f);
      }
      for (final runs in byM.values) {
        if (runs.length >= 2) {
          x = runs[1].name;
          y = runs[0].name;
          break;
        }
      }
      _a = _Side(x, 'opt');
      _b = _Side(y, 'opt');
    } else {
      _a = _Side(first, 'ref');
      _b = _Side(first, 'opt');
    }
  }

  Widget _sidePicker(String label, _Side s, List<ResultFile> files) {
    final f = s.file == null ? null : widget.repo.byName(s.file!);
    return Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      FileDropdown(
        label: label,
        files: files,
        value: f,
        onChanged: (v) => setState(() => s.file = v?.name),
      ),
      DropdownButton<String>(
        value: s.tier,
        onChanged: (v) => setState(() => s.tier = v ?? s.tier),
        items: [for (final t in e1Tiers) DropdownMenuItem(value: t, child: Text(e1TierLabels[t]!))],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final files = repo.of('e1');
    if (files.isEmpty) return const Center(child: Text('No E1 results yet: run `make bench`.'));
    final fa = repo.byName(_a.file ?? '') ?? files.first;
    final fb = repo.byName(_b.file ?? '') ?? files.first;
    final ia = E1Index(fa), ib = E1Index(fb);
    final fmt = e1Format(_metric);
    final thr = _threshold / 100;

    final rows = <List<TCell>>[];
    final logs = <double>[];
    var within = 0, slower = 0, faster = 0;
    final order = repo.catalog.sort({...ia.algs, ...ib.algs});
    for (final alg in order) {
      for (final op in e1Ops) {
        final ra = ia.get(_a.tier, alg, op), rb = ib.get(_b.tier, alg, op);
        if (ra == null || rb == null) continue;
        final pa = e1Point(ra, _metric), pb = e1Point(rb, _metric);
        if (pa == null || pb == null) continue;
        final ratio = pb.value / pa.value;
        logs.add(math.log(ratio));
        final String verdict;
        final Color color;
        if (ratio > 1 + thr) {
          verdict = 'B ${fmtRatio(ratio)} slower';
          color = badRed;
          slower++;
        } else if (ratio < 1 / (1 + thr)) {
          verdict = 'B ${fmtRatio(1 / ratio)} faster';
          color = okGreen;
          faster++;
        } else {
          verdict = 'within ±${_threshold.round()}%';
          color = Theme.of(context).colorScheme.onSurfaceVariant;
          within++;
          if (_onlyDifferent) continue;
        }
        rows.add([
          TCell(alg, sort: order.indexOf(alg)),
          TCell(op, sort: e1Ops.indexOf(op)),
          TCell.number(pa.value, fmt),
          TCell.number(pb.value, fmt),
          TCell(fmtRatio(ratio), sort: ratio, widget: Text(fmtRatio(ratio), style: TextStyle(color: color))),
          TCell(fmtPct((ratio - 1) * 100), sort: ratio),
          TCell(verdict, sort: ratio, widget: Pill(verdict, color)),
        ]);
      }
    }
    final geo = logs.isEmpty ? null : math.exp(logs.reduce((x, y) => x + y) / logs.length);
    final sorted = [...logs]..sort();
    final med = sorted.isEmpty ? null : math.exp(sorted[sorted.length ~/ 2]);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Section(
          title: 'Compare two runs or builds',
          subtitle: 'Ratio = B / A per KEM and operation. Same run with ref vs opt gives the speed-up '
              'from AVX2/NEON; two runs of one machine show repeatability.',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton(onPressed: () => setState(() => _preset('opt-vs-ref')), child: const Text('opt vs ref')),
              OutlinedButton(onPressed: () => setState(() => _preset('repeat')), child: const Text('Repeat run')),
              OutlinedButton(onPressed: () => setState(() => _preset('machines')), child: const Text('Machine vs machine')),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  final t = _a;
                  _a = _b;
                  _b = t;
                }),
                icon: const Icon(Icons.swap_vert, size: 18),
                label: const Text('Swap A/B'),
              ),
            ]),
            const SizedBox(height: 8),
            _sidePicker('A', _a, files),
            _sidePicker('B', _b, files),
            ControlRow(
              'Metric',
              SegmentedButton<E1Metric>(
                segments: [
                  for (final m in [E1Metric.time, E1Metric.cycles])
                    ButtonSegment(value: m, label: Text(e1MetricLabels[m]!)),
                ],
                selected: {_metric == E1Metric.ticks ? E1Metric.time : _metric},
                onSelectionChanged: (s) => setState(() => _metric = s.first),
              ),
            ),
            ControlRow(
              'Tolerance',
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(
                  width: 260,
                  child: Slider(
                    min: 5,
                    max: 50,
                    divisions: 9,
                    value: _threshold,
                    label: '±${_threshold.round()}%',
                    onChanged: (v) => setState(() => _threshold = v),
                  ),
                ),
                Text('±${_threshold.round()}%'),
                const SizedBox(width: 16),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Checkbox(value: _onlyDifferent, onChanged: (v) => setState(() => _onlyDifferent = v ?? false)),
                  const Text('only rows outside the tolerance'),
                ]),
              ]),
            ),
          ]),
        ),
        Section(
          title: 'Summary',
          child: Wrap(spacing: 24, runSpacing: 8, children: [
            _Stat('Rows compared', '${within + slower + faster}'),
            _Stat('Within ±${_threshold.round()}%', '$within'),
            _Stat('B slower', '$slower'),
            _Stat('B faster', '$faster'),
            if (med != null) _Stat('Median B/A', fmtRatio(med)),
            if (geo != null) _Stat('Geometric mean B/A', fmtRatio(geo)),
          ]),
        ),
        Section(
          title: 'Rows',
          child: SortableTable(
            columns: const ['KEM', 'Op', 'A', 'B', 'B / A', 'Change', 'Verdict'],
            numeric: const {2, 3, 4, 5},
            rows: rows,
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: t.headlineSmall),
      Text(label, style: t.bodySmall),
    ]);
  }
}
