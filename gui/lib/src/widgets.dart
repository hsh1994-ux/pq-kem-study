// Small building blocks shared by the pages.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'data.dart';

/// Base colours, one per run/machine; builds are shades of it.
const runPalette = <Color>[
  Color(0xFF3B6FD8), // blue
  Color(0xFFE07B28), // orange
  Color(0xFF2E9E5B), // green
  Color(0xFF8E4EC6), // purple
  Color(0xFF169C9C), // teal
  Color(0xFFD04545), // red
  Color(0xFF8A7A1E), // olive
  Color(0xFFC2459A), // pink
];

Color tierShade(Color base, String tier) {
  switch (tier) {
    case 'ref':
      return Color.lerp(base, Colors.white, 0.45)!;
    case 'openssl':
      return Color.lerp(base, Colors.black, 0.35)!;
    default:
      return base;
  }
}

/// A titled card section with optional trailing actions.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.actions = const [], this.subtitle});
  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ),
                ]),
              ),
              ...actions,
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Coloured pill, e.g. PASS / FAIL / leak.
class Pill extends StatelessWidget {
  const Pill(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withAlpha(160)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

const okGreen = Color(0xFF2E9E5B);
const warnAmber = Color(0xFFC98A00);
const badRed = Color(0xFFD04545);

Color statusColor(String s) {
  final v = s.toLowerCase();
  if (v == 'pass' || v == 'no_evidence' || v == 'ok' || v == 'true') return okGreen;
  if (v == 'fail' || v == 'leak' || v == 'error') return badRed;
  return warnAmber;
}

/// One table cell: display text, optional widget, and a sort key.
class TCell {
  const TCell(this.text, {this.sort, this.widget});
  TCell.number(double? v, String Function(double) f)
      : text = v == null ? '—' : f(v),
        sort = v,
        widget = null;

  final String text;
  final Comparable? sort;
  final Widget? widget;
}

/// DataTable with click-to-sort headers and a "copy as TSV" button
/// (pastes straight into Excel, Numbers or a LaTeX table generator).
class SortableTable extends StatefulWidget {
  const SortableTable({
    super.key,
    required this.columns,
    required this.rows,
    this.numeric = const {},
    this.title,
    this.subtitle,
    this.maxRows = 2000,
  });

  final List<String> columns;
  final List<List<TCell>> rows;
  final Set<int> numeric;
  final String? title;
  final String? subtitle;
  final int maxRows;

  @override
  State<SortableTable> createState() => _SortableTableState();
}

class _SortableTableState extends State<SortableTable> {
  int? _sortCol;
  bool _asc = true;

  int _cmp(TCell a, TCell b) {
    final Comparable x = a.sort ?? a.text;
    final Comparable y = b.sort ?? b.text;
    if (a.sort == null && b.sort != null) return 1;
    if (b.sort == null && a.sort != null) return -1;
    try {
      return x.compareTo(y);
    } catch (_) {
      return a.text.compareTo(b.text);
    }
  }

  String _tsv() {
    final b = StringBuffer()..writeln(widget.columns.join('\t'));
    for (final r in widget.rows) {
      b.writeln(r.map((c) => c.text).join('\t'));
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    var rows = widget.rows;
    final sc = _sortCol;
    if (sc != null && sc < widget.columns.length) {
      rows = [...rows]..sort((a, b) => _asc ? _cmp(a[sc], b[sc]) : _cmp(b[sc], a[sc]));
    }
    final shown = rows.length > widget.maxRows ? rows.sublist(0, widget.maxRows) : rows;
    final table = DataTable(
      sortColumnIndex: sc,
      sortAscending: _asc,
      headingRowHeight: 36,
      dataRowMinHeight: 28,
      dataRowMaxHeight: 40,
      columnSpacing: 20,
      horizontalMargin: 12,
      columns: [
        for (var i = 0; i < widget.columns.length; i++)
          DataColumn(
            label: Text(widget.columns[i], style: const TextStyle(fontWeight: FontWeight.w600)),
            numeric: widget.numeric.contains(i),
            onSort: (col, asc) => setState(() {
              _sortCol = col;
              _asc = asc;
            }),
          ),
      ],
      rows: [
        for (final r in shown)
          DataRow(cells: [
            for (var i = 0; i < widget.columns.length; i++)
              DataCell(i < r.length ? (r[i].widget ?? Text(r[i].text)) : const Text('')),
          ]),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (widget.title != null)
            Expanded(child: Text(widget.title!, style: Theme.of(context).textTheme.titleSmall))
          else
            const Spacer(),
          Text('${widget.rows.length} rows', style: Theme.of(context).textTheme.bodySmall),
          IconButton(
            tooltip: 'Copy table (tab-separated)',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _tsv()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Table copied as tab-separated text')),
              );
            },
          ),
        ]),
        if (widget.subtitle != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(widget.subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: table),
        if (shown.length < rows.length)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Showing the first ${shown.length} of ${rows.length} rows.'),
          ),
      ],
    );
  }
}

/// Dropdown over result files (newest first).
class FileDropdown extends StatelessWidget {
  const FileDropdown({super.key, required this.files, required this.value, required this.onChanged, this.label});
  final List<ResultFile> files;
  final ResultFile? value;
  final ValueChanged<ResultFile?> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const Text('No files for this experiment yet.');
    final v = value != null && files.contains(value) ? value : files.first;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (label != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text(label!)),
      DropdownButton<ResultFile>(
        value: v,
        onChanged: onChanged,
        items: [
          for (final f in files)
            DropdownMenuItem(value: f, child: Text(f.label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    ]);
  }
}

/// Wraps a chart so it can be saved as a PNG (for the report or slides).
class ExportableChart extends StatefulWidget {
  const ExportableChart({super.key, required this.child, required this.fileStem, required this.outDir});
  final Widget child;
  final String fileStem;

  /// Usually <repo>/figures/gui.
  final String outDir;

  @override
  State<ExportableChart> createState() => _ExportableChartState();
}

class _ExportableChartState extends State<ExportableChart> {
  final _key = GlobalKey();

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ro = _key.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      final image = await ro.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final dir = Directory(widget.outDir);
      await dir.create(recursive: true);
      final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);
      final safe = widget.fileStem.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final f = File('${dir.path}${Platform.pathSeparator}${safe}_$ts.png');
      await f.writeAsBytes(data.buffer.asUint8List());
      messenger.showSnackBar(SnackBar(content: Text('Saved ${f.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save the chart: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepaintBoundary(
          key: _key,
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.all(8),
            child: widget.child,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('Save chart as PNG'),
          ),
        ),
      ],
    );
  }
}

/// Wrap of filter chips for a multi-select over strings.
class ChipSet extends StatelessWidget {
  const ChipSet({super.key, required this.options, required this.selected, required this.onChanged, this.labels});
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Map<String, String>? labels;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final o in options)
        FilterChip(
          label: Text(labels?[o] ?? o),
          selected: selected.contains(o),
          onSelected: (on) {
            final s = {...selected};
            if (on) {
              s.add(o);
            } else {
              s.remove(o);
            }
            onChanged(s);
          },
        ),
    ]);
  }
}

/// Labelled row of controls.
class ControlRow extends StatelessWidget {
  const ControlRow(this.label, this.child, {super.key});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 110, child: Text(label, style: Theme.of(context).textTheme.labelLarge)),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
      ]),
    );
  }
}

/// Key/value table used for machine metadata.
class KeyValueTable extends StatelessWidget {
  const KeyValueTable(this.entries, {super.key});
  final Map<String, String> entries;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final e in entries.entries)
          TableRow(children: [
            Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 2),
              child: Text(e.key, style: style?.copyWith(fontWeight: FontWeight.w600)),
            ),
            Padding(padding: const EdgeInsets.only(bottom: 2), child: SelectableText(e.value, style: style)),
          ]),
      ],
    );
  }
}
