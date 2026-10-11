// Helpers for E1 (microbenchmark) rows.
import 'data.dart';
import 'format.dart';

enum E1Metric { time, cycles, ticks }

const e1MetricLabels = {
  E1Metric.time: 'Time',
  E1Metric.cycles: 'Core cycles (est.)',
  E1Metric.ticks: 'Timer ticks',
};

const e1Ops = ['keygen', 'encaps', 'decaps'];
const e1Tiers = ['ref', 'opt', 'openssl'];
const e1TierLabels = {
  'ref': 'ref (portable C)',
  'opt': 'opt (AVX2 / NEON)',
  'openssl': 'OpenSSL 3.5',
};

class E1Point {
  const E1Point(this.value, this.lo, this.hi);
  final double value;
  final double? lo;
  final double? hi;
}

/// Value and IQR of one row in the chosen metric, or null if unavailable
/// (core cycles exist only in runs made after the calibration update).
E1Point? e1Point(Map<String, String> row, E1Metric m) {
  if (m == E1Metric.time) {
    final v = numOf(row, 'median_ns');
    if (v == null || v <= 0) return null;
    return E1Point(v, numOf(row, 'p25_ns'), numOf(row, 'p75_ns'));
  }
  if (m == E1Metric.cycles) {
    final est = numOf(row, 'median_core_cycles_est');
    final ns = numOf(row, 'median_ns');
    if (est == null || est <= 0 || ns == null || ns <= 0) return null;
    final f = est / ns;
    final lo = numOf(row, 'p25_ns'), hi = numOf(row, 'p75_ns');
    return E1Point(est, lo == null ? null : lo * f, hi == null ? null : hi * f);
  }
  final v = numOf(row, 'median');
  if (v == null || v <= 0) return null;
  return E1Point(v, numOf(row, 'p25'), numOf(row, 'p75'));
}

String Function(double) e1Format(E1Metric m) => m == E1Metric.time ? fmtNs : fmtCount;

/// Rows of one E1 file indexed by tier|alg|op.
class E1Index {
  E1Index(ResultFile f) {
    for (final r in f.rows) {
      final k = key(r['tier'] ?? '', r['alg'] ?? '', r['op'] ?? '');
      rows[k] = r;
      tiers.add(r['tier'] ?? '');
      algs.add(r['alg'] ?? '');
    }
  }

  final rows = <String, Map<String, String>>{};
  final tiers = <String>{};
  final algs = <String>{};

  static String key(String tier, String alg, String op) => '$tier|$alg|$op';

  Map<String, String>? get(String tier, String alg, String op) => rows[key(tier, alg, op)];
}

/// Short tier label for series names.
String tierShort(String t) => t == 'openssl' ? 'OpenSSL' : t;
