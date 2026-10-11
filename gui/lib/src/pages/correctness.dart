// E4: KATs, NIST ACVP vectors, ref<->opt and liboqs<->OpenSSL cross-checks.
import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

class CorrectnessPage extends StatefulWidget {
  const CorrectnessPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<CorrectnessPage> createState() => _CorrectnessPageState();
}

class _CorrectnessPageState extends State<CorrectnessPage> {
  String? _file;
  bool _onlyProblems = false;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final files = repo.of('e4');
    if (files.isEmpty) return const Center(child: Text('No E4 results yet: run `make kat`.'));
    final f = repo.byName(_file ?? '') ?? files.first;
    final counts = <String, int>{};
    var passed = 0, total = 0;
    for (final r in f.rows) {
      final s = r['status'] ?? '?';
      counts[s] = (counts[s] ?? 0) + 1;
      passed += (numOf(r, 'passed') ?? 0).round();
      total += (numOf(r, 'total') ?? 0).round();
    }
    final checks = <String>{for (final r in f.rows) r['check'] ?? ''}.toList();
    final rows = [
      for (final r in f.rows)
        if (!_onlyProblems || (r['status'] ?? '') != 'PASS')
          [
            TCell(r['check'] ?? '', sort: checks.indexOf(r['check'] ?? '')),
            TCell(r['tier'] ?? ''),
            TCell(r['alg'] ?? '', sort: repo.catalog.sort(f.rows.map((x) => x['alg'] ?? '')).indexOf(r['alg'] ?? '')),
            TCell('${r['passed']} / ${r['total']}', sort: numOf(r, 'passed')),
            TCell(r['status'] ?? '', widget: Pill(r['status'] ?? '?', statusColor(r['status'] ?? ''))),
            TCell(r['detail'] ?? ''),
          ],
    ];
    final allPass = counts.keys.every((k) => k == 'PASS' || k == 'SKIP');
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Section(
        title: 'E4 · Correctness',
        subtitle: 'kat: liboqs known-answer tests · selftest: random round trips · acvp: NIST ACVP FIPS 203 '
            'vectors · cross: ref vs opt and liboqs vs OpenSSL on the same inputs.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          FileDropdown(files: files, value: f, onChanged: (v) => setState(() => _file = v?.name)),
          const SizedBox(height: 12),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Icon(allPass ? Icons.verified : Icons.error_outline, color: allPass ? okGreen : badRed, size: 28),
            const SizedBox(width: 10),
            Text(
              allPass ? 'All ${f.rows.length} checks passed' : 'Some checks did not pass',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(width: 16),
            Text('($passed of $total individual vectors / round trips)'),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final e in counts.entries) Pill('${e.key}: ${e.value}', statusColor(e.key)),
          ]),
          Row(children: [
            Checkbox(value: _onlyProblems, onChanged: (v) => setState(() => _onlyProblems = v ?? false)),
            const Text('show only checks that did not pass'),
          ]),
        ]),
      ),
      Section(
        title: 'Checks',
        child: SortableTable(
          columns: const ['Check', 'Build', 'KEM', 'Passed', 'Status', 'Detail'],
          numeric: const {3},
          rows: rows,
        ),
      ),
    ]);
  }
}
