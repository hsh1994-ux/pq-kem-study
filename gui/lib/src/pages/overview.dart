// One card per machine: what it is, what has been run on it, headline numbers.
import 'package:flutter/material.dart';

import '../data.dart';
import '../e1.dart';
import '../format.dart';
import '../widgets.dart';
import 'files.dart' show experimentNames;

const _headline = [
  ('X25519', 'openssl'),
  ('X25519MLKEM768', 'openssl'),
  ('ML-KEM-768', 'opt'),
  ('HQC-3', 'opt'),
  ('FrodoKEM-976-SHAKE', 'opt'),
  ('Classic-McEliece-460896', 'opt'),
];

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  Widget build(BuildContext context) {
    final machines = repo.byMachine();
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Section(
        title: 'Results folder',
        subtitle: repo.dir,
        child: Wrap(spacing: 24, runSpacing: 8, children: [
          _Count('files', repo.files.length),
          _Count('machines', machines.length),
          for (final e in experimentNames.entries) _Count(e.value, repo.of(e.key).length),
        ]),
      ),
      for (final entry in machines.entries) _machineCard(context, theme, entry.value),
      if (repo.errors.isNotEmpty)
        Section(
          title: 'Files that could not be read',
          child: Text(repo.errors.join('\n'), style: TextStyle(color: theme.colorScheme.error)),
        ),
    ]);
  }

  Widget _machineCard(BuildContext context, ThemeData theme, List<ResultFile> files) {
    final newest = files.first; // repo.files is sorted newest first
    final meta = newest.meta;
    final counts = <String, int>{};
    for (final f in files) {
      counts[f.experiment] = (counts[f.experiment] ?? 0) + 1;
    }
    ResultFile? latest(String exp) {
      ResultFile? any;
      for (final f in files) {
        if (f.experiment != exp) continue;
        if (!f.quick) return f;
        any ??= f;
      }
      return any;
    }

    final e4 = latest('e4');
    Widget? e4Status;
    if (e4 != null) {
      final bad = e4.rows.where((r) => r['status'] != 'PASS' && r['status'] != 'SKIP').length;
      e4Status = Pill(bad == 0 ? 'E4: all ${e4.rows.length} checks PASS' : 'E4: $bad checks not passing',
          bad == 0 ? okGreen : badRed);
    }
    final e1 = latest('e1');
    final headRows = <List<TCell>>[];
    if (e1 != null) {
      final idx = E1Index(e1);
      for (final (alg, tier) in _headline) {
        final cells = <TCell>[TCell(alg), TCell(tierShort(tier))];
        var any = false;
        for (final op in e1Ops) {
          final r = idx.get(tier, alg, op);
          final p = r == null ? null : e1Point(r, E1Metric.time);
          if (p != null) any = true;
          cells.add(TCell.number(p?.value, fmtNs));
        }
        if (any) headRows.add(cells);
      }
    }
    final virt = meta['virtualisation'] ?? '';
    return Section(
      title: newest.machineLabel,
      subtitle: [
        if (virt.isNotEmpty && virt != 'none detected') virt,
        if ((meta['cores'] ?? '').isNotEmpty) '${meta['cores']} cores',
        if ((meta['host'] ?? '').isNotEmpty) 'host ${meta['host']}',
      ].join(' · '),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final e in experimentNames.entries)
            if (counts.containsKey(e.key)) Pill('${e.value}: ${counts[e.key]} run${counts[e.key] == 1 ? '' : 's'}', theme.colorScheme.primary),
          if (e4Status != null) e4Status,
        ]),
        const SizedBox(height: 12),
        KeyValueTable({
          'CPU': meta['cpu'] ?? newest.arch,
          'Kernel': meta['kernel'] ?? '',
          'Compiler': meta['cc'] ?? '',
          'Versions': 'liboqs ${meta['liboqs'] ?? '?'}, OpenSSL ${(meta['openssl'] ?? '?').replaceAll('openssl-', '')}, '
              'oqs-provider ${meta['oqs_provider'] ?? '?'}',
          'Newest run': '${newest.timeLabel} (${experimentNames[newest.experiment] ?? newest.experiment})',
          if (e1?.meta['tick_mhz'] != null) 'Timer': '${e1!.meta['tick_mhz']} MHz, core ~${e1!.meta['core_ghz_at_start'] ?? '?'} GHz at start',
        }),
        if (headRows.isNotEmpty) ...[
          const SizedBox(height: 12),
          SortableTable(
            title: 'Headline medians (newest E1 run, ${e1!.timeLabel})',
            columns: const ['KEM', 'Build', 'keygen', 'encaps', 'decaps'],
            numeric: const {2, 3, 4},
            rows: headRows,
          ),
        ],
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value);
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$value', style: t.headlineSmall),
      Text(label, style: t.bodySmall),
    ]);
  }
}
