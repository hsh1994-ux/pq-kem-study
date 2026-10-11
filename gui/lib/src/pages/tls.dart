// E2: TLS 1.3 handshakes per key-exchange group, under emulated delay/loss.
import 'package:flutter/material.dart';

import '../bar_chart.dart';
import '../data.dart';
import '../format.dart';
import '../widgets.dart';

const _groupOrder = [
  'x25519', 'X25519MLKEM768', 'MLKEM512', 'MLKEM768', 'MLKEM1024', 'hqc1', 'hqc3', 'hqc5', //
  'frodo640shake', 'frodo976shake', 'frodo1344shake', 'mceliece348864',
];

double? _pct(List<double> s, double p) {
  if (s.isEmpty) return null;
  final i = (p * (s.length - 1)).round();
  return s[i];
}

class TlsPage extends StatefulWidget {
  const TlsPage({super.key, required this.repo});
  final ResultsRepo repo;

  @override
  State<TlsPage> createState() => _TlsPageState();
}

class _TlsPageState extends State<TlsPage> {
  String? _file;
  String? _cell; // "rtt|loss"
  String _metric = 'time';
  bool _log = true;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final files = repo.of('e2');
    if (files.isEmpty) {
      return const Center(child: Text('No E2 results yet: run `make tls` (Linux / WSL2 / Docker).'));
    }
    final f = repo.byName(_file ?? '') ?? files.first;
    final ok = f.rows.where((r) => r['ok'] == '1').toList();
    final cells = <String>{for (final r in f.rows) if ((r['rtt_ms'] ?? '').isNotEmpty) '${r['rtt_ms']}|${r['loss_pct']}'}
        .toList()
      ..sort((a, b) {
        final x = a.split('|').map((v) => double.tryParse(v) ?? 0.0).toList();
        final y = b.split('|').map((v) => double.tryParse(v) ?? 0.0).toList();
        final c = x[0].compareTo(y[0]);
        return c != 0 ? c : x[1].compareTo(y[1]);
      });
    final cell = cells.contains(_cell) ? _cell! : (cells.isEmpty ? '' : cells.first);
    final parts = cell.split('|');

    final groups = <String>{for (final r in f.rows) r['group'] ?? ''}.toList()
      ..sort((a, b) {
        int rank(String g) {
          final i = _groupOrder.indexOf(g);
          return i < 0 ? 999 : i;
        }

        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : a.compareTo(b);
      });
    final notes = <String, String>{
      for (final r in f.rows)
        if ((r['note'] ?? '').isNotEmpty && r['ok'] != '1') r['group'] ?? '': r['note']!,
    };

    final chartGroups = <ChartGroup>[];
    final rows = <List<TCell>>[];
    for (final g in groups) {
      final inCell = f.rows.where((r) => r['group'] == g && r['rtt_ms'] == parts[0] && r['loss_pct'] == (parts.length > 1 ? parts[1] : ''));
      final attempts = inCell.length;
      final good = ok.where((r) => r['group'] == g && r['rtt_ms'] == parts[0] && r['loss_pct'] == (parts.length > 1 ? parts[1] : '')).toList();
      List<double> col(String c) => good.map((r) => numOf(r, c)).whereType<double>().toList()..sort();
      final total = col('total_ns'), tls = col('tls_ns'), tcp = col('tcp_ns'), sent = col('bytes_sent'), recv = col('bytes_received');
      if (good.isEmpty) {
        if (notes.containsKey(g)) {
          rows.add([TCell(g), const TCell('0'), const TCell('—'), TCell(notes[g]!), const TCell(''), const TCell(''), const TCell(''), const TCell(''), const TCell('')]);
        }
        continue;
      }
      final med = _pct(total, .5)!;
      final bytes = (_pct(sent, .5) ?? 0.0) + (_pct(recv, .5) ?? 0.0);
      if (_metric == 'time') {
        chartGroups.add(ChartGroup(g, [
          ChartBar(
            series: 0,
            value: med,
            lo: _pct(total, .25),
            hi: _pct(total, .75),
            tooltip: '$g: median ${fmtNs(med)} over ${good.length} handshakes',
          ),
        ]));
      } else {
        chartGroups.add(ChartGroup(g, [
          ChartBar(series: 0, value: _pct(sent, .5) ?? 0.0, tooltip: '$g client → server: ${fmtBytes(_pct(sent, .5) ?? 0.0)}'),
          ChartBar(series: 1, value: _pct(recv, .5) ?? 0.0, tooltip: '$g server → client: ${fmtBytes(_pct(recv, .5) ?? 0.0)}'),
        ]));
      }
      rows.add([
        TCell(g, sort: groups.indexOf(g)),
        TCell('${good.length}', sort: good.length),
        TCell.number(attempts == 0 ? null : good.length / attempts * 100, (v) => '${v.toStringAsFixed(0)}%'),
        TCell.number(med, fmtNs),
        TCell.number(_pct(total, .25), fmtNs),
        TCell.number(_pct(total, .75), fmtNs),
        TCell.number(_pct(tcp, .5), fmtNs),
        TCell.number(_pct(tls, .5), fmtNs),
        TCell.number(bytes, groupDigits),
      ]);
    }

    final series = _metric == 'time'
        ? const [ChartSeries('handshake', Color(0xFF3B6FD8))]
        : const [ChartSeries('client → server', Color(0xFF3B6FD8)), ChartSeries('server → client', Color(0xFFE07B28))];

    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      Section(
        title: 'E2 · TLS 1.3 handshakes',
        subtitle: 'Loopback in a private network namespace, MTU ${f.rows.isNotEmpty ? f.rows.first['mtu'] : '?'}; '
            'delay and loss added with tc netem.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ControlRow(
            'Run',
            FileDropdown(files: files, value: f, onChanged: (v) => setState(() => _file = v?.name)),
          ),
          ControlRow(
            'Network',
            cells.isEmpty
                ? const Text('—')
                : DropdownButton<String>(
                    value: cell,
                    onChanged: (v) => setState(() => _cell = v),
                    items: [
                      for (final c in cells)
                        DropdownMenuItem(
                          value: c,
                          child: Text('RTT ${c.split('|')[0]} ms · loss ${c.split('|').length > 1 ? c.split('|')[1] : '0'}%'),
                        ),
                    ],
                  ),
          ),
          ControlRow(
            'Show',
            Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'time', label: Text('Handshake time')),
                  ButtonSegment(value: 'bytes', label: Text('Bytes on the wire')),
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
        ]),
      ),
      Section(
        title: _metric == 'time' ? 'Median full handshake (TCP connect + TLS)' : 'Median bytes per handshake',
        child: ExportableChart(
          fileStem: 'e2_${_metric}_${cell.replaceAll('|', '_')}',
          outDir: '${repo.repoRoot}${ResultsRepo.sep}figures${ResultsRepo.sep}gui',
          child: HBarChart(
            series: series,
            groups: chartGroups,
            format: _metric == 'time' ? fmtNs : fmtCount,
            log: _log,
            labelWidth: 150,
          ),
        ),
      ),
      Section(
        title: 'Table',
        child: SortableTable(
          columns: const ['Group', 'OK', 'Success', 'Median total', 'p25', 'p75', 'TCP', 'TLS', 'Bytes'],
          numeric: const {1, 2, 3, 4, 5, 6, 7, 8},
          rows: rows,
        ),
      ),
    ]);
  }
}
