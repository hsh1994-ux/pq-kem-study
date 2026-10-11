// Number formatting shared by charts and tables.

/// Three significant digits, without exponent notation.
String sig3(double v) {
  final a = v.abs();
  if (a >= 100) return v.toStringAsFixed(0);
  if (a >= 10) return v.toStringAsFixed(1);
  if (a >= 1) return v.toStringAsFixed(2);
  return v.toStringAsPrecision(3);
}

/// Nanoseconds -> "812 ns", "8.44 µs", "31.1 ms", "1.20 s".
String fmtNs(double ns) {
  final a = ns.abs();
  if (a < 1e3) return '${sig3(ns)} ns';
  if (a < 1e6) return '${sig3(ns / 1e3)} µs';
  if (a < 1e9) return '${sig3(ns / 1e6)} ms';
  return '${sig3(ns / 1e9)} s';
}

/// Plain counts -> "812", "15.6k", "57.4M", "1.20G".
String fmtCount(double v) {
  final a = v.abs();
  if (a < 1e3) return sig3(v);
  if (a < 1e6) return '${sig3(v / 1e3)}k';
  if (a < 1e9) return '${sig3(v / 1e6)}M';
  return '${sig3(v / 1e9)}G';
}

/// 261120 -> "261,120".
String groupDigits(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return v < 0 ? '-$b' : b.toString();
}

/// Bytes -> "1,184 B" or "261,120 B (255 KiB)".
String fmtBytes(num b) {
  if (b < 0) return '—';
  if (b < 10240) return '${groupDigits(b)} B';
  return '${groupDigits(b)} B (${sig3(b / 1024)} KiB)';
}

/// Ratio -> "3.21×".
String fmtRatio(double r) => '${sig3(r)}×';

String fmtPct(double p) => '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%';
