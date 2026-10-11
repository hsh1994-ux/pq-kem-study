// Every results file with its machine metadata and raw rows.
import 'package:flutter/material.dart';

import '../data.dart';
import '../widgets.dart';

const experimentNames = {
  'e1': 'E1 performance',
  'e2': 'E2 TLS',
  'e3dudect': 'E3 dudect',
  'e3divscan': 'E3 DIV scan',
  'e3valgrind': 'E3 Valgrind',
  'e4': 'E4 correctness',
};

/// Numbers sort numerically, everything else as text.
Comparable _sortKey(String? s) {
  final d = double.tryParse(s ?? '');
  if (d != null) return d;
  return s ?? '';
}

class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final files = [...repo.files]..sort((a, b) {
        final c = a.experiment.compareTo(b.experiment);
        return c != 0 ? c : (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0));
      });
    if (files.isEmpty) return const Center(child: Text('No results files in this folder.'));
    final sel = repo.byName(_selected ?? '') ?? files.first;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 340,
        child: ListView(children: [
          for (final f in files)
            ListTile(
              dense: true,
              selected: f.name == sel.name,
              title: Text('${experimentNames[f.experiment] ?? f.experiment}${f.quick ? ' (quick)' : ''}'),
              subtitle: Text('${f.machineLabel}\n${f.timeLabel} · ${f.rows.length} rows'),
              isThreeLine: true,
              onTap: () => setState(() => _selected = f.name),
            ),
          if (repo.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Could not read:\n${repo.errors.join('\n')}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Section(
            title: sel.name,
            subtitle: sel.path,
            child: KeyValueTable(sel.meta),
          ),
          Section(
            title: 'Rows',
            child: SortableTable(
              columns: sel.columns,
              maxRows: 500,
              rows: [
                for (final r in sel.rows)
                  [
                    for (final c in sel.columns)
                      TCell(r[c] ?? '', sort: _sortKey(r[c])),
                  ],
              ],
            ),
          ),
        ]),
      ),
    ]);
  }
}
