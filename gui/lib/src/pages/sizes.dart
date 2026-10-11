// Key, ciphertext and shared-secret sizes (identical on every machine).
import 'package:flutter/material.dart';

import '../bar_chart.dart';
import '../data.dart';
import '../format.dart';
import '../widgets.dart';

class SizesPage extends StatelessWidget {
  const SizesPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  Widget build(BuildContext context) {
    final files = repo.of('e1');
    if (files.isEmpty) return const Center(child: Text('No E1 results yet: run `make bench`.'));
    // Sizes do not depend on the machine; take each KEM's first keygen row.
    final byAlg = <String, Map<String, String>>{};
    for (final f in files) {
      for (final r in f.rows) {
        if (r['op'] != 'keygen') continue;
        final alg = r['alg'] ?? '';
        final cur = byAlg[alg];
        // Prefer liboqs rows (they also report the secret-key size).
        if (cur == null || (cur['tier'] == 'openssl' && r['tier'] != 'openssl')) byAlg[alg] = r;
      }
    }
    final algs = repo.catalog.sort(byAlg.keys);
    final series = const [
      ChartSeries('public key', Color(0xFF3B6FD8)),
      ChartSeries('ciphertext', Color(0xFFE07B28)),
    ];
    final groups = <ChartGroup>[];
    final rows = <List<TCell>>[];
    for (final a in algs) {
      final r = byAlg[a]!;
      final pk = numOf(r, 'pk_bytes'), sk = numOf(r, 'sk_bytes'), ct = numOf(r, 'ct_bytes'), ss = numOf(r, 'ss_bytes');
      groups.add(ChartGroup(a, [
        if (pk != null && pk > 0) ChartBar(series: 0, value: pk, tooltip: '$a public key: ${fmtBytes(pk)}'),
        if (ct != null && ct > 0) ChartBar(series: 1, value: ct, tooltip: '$a ciphertext: ${fmtBytes(ct)}'),
      ]));
      final wire = (pk ?? 0.0) + (ct ?? 0.0);
      rows.add([
        TCell(a, sort: algs.indexOf(a)),
        TCell('${repo.catalog.levelOf(a) == 0 ? 'baseline' : repo.catalog.levelOf(a)}'),
        TCell.number(pk, groupDigits),
        TCell.number(sk != null && sk >= 0 ? sk : null, groupDigits),
        TCell.number(ct, groupDigits),
        TCell.number(ss, groupDigits),
        TCell.number(wire, groupDigits),
        TCell(pk != null && pk > 65535 ? 'no' : 'yes', sort: pk ?? 0.0),
      ]);
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Section(
        title: 'Sizes',
        subtitle: 'Bytes. "On the wire" = public key + ciphertext, what a key exchange sends. '
            'A TLS 1.3 key share is limited to 65,535 bytes.',
        child: ExportableChart(
          fileStem: 'sizes',
          outDir: '${repo.repoRoot}${ResultsRepo.sep}figures${ResultsRepo.sep}gui',
          child: HBarChart(series: series, groups: groups, format: fmtCount, axisTitle: 'bytes'),
        ),
      ),
      Section(
        title: 'Table',
        child: SortableTable(
          columns: const ['KEM', 'Level', 'Public key', 'Secret key', 'Ciphertext', 'Shared secret', 'On the wire', 'Fits a TLS key share'],
          numeric: const {2, 3, 4, 5, 6},
          rows: rows,
        ),
      ),
    ]);
  }
}
