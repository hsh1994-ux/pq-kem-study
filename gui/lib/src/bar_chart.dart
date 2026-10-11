// Horizontal grouped bar chart built from plain widgets (no chart package):
// one group per label (e.g. a KEM), one bar per series (e.g. machine x build),
// optional IQR whiskers, log or linear axis, hover tooltips, and an optional
// threshold line (e.g. dudect's |t| = 10).
import 'dart:math' as math;

import 'package:flutter/material.dart';

class ChartSeries {
  const ChartSeries(this.name, this.color);
  final String name;
  final Color color;
}

class ChartBar {
  const ChartBar({
    required this.series,
    required this.value,
    this.lo,
    this.hi,
    this.tooltip,
    this.color,
  });

  /// Index into [HBarChart.series].
  final int series;
  final double value;
  final double? lo;
  final double? hi;
  final String? tooltip;

  /// Overrides the series colour for this bar.
  final Color? color;
}

class ChartGroup {
  const ChartGroup(this.label, this.bars);
  final String label;
  final List<ChartBar> bars;
}

class _Scale {
  _Scale(double minV, double maxV, this.log, this.width) {
    if (log) {
      final mn = math.max(minV, 1e-12);
      final mx = math.max(maxV, mn * 1.0001);
      a = (math.log(mn) / math.ln10).floorToDouble();
      b = (math.log(mx) / math.ln10).ceilToDouble();
      if (b <= a) b = a + 1;
    } else {
      a = 0;
      b = _niceCeil(math.max(maxV, 1e-12));
    }
  }

  final bool log;
  final double width;
  late double a;
  late double b;

  static double _niceCeil(double v) {
    final e = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (m * e >= v) return m * e;
    }
    return 10 * e;
  }

  double x(double v) {
    double t;
    if (log) {
      if (v <= 0) return 0;
      t = (math.log(v) / math.ln10 - a) / (b - a);
    } else {
      t = (v - a) / (b - a);
    }
    return (t.clamp(0.0, 1.0)) * width;
  }

  List<double> ticks() {
    final out = <double>[];
    if (log) {
      final decades = (b - a).round();
      for (var e = a.round(); e <= b.round(); e++) {
        final p = math.pow(10, e).toDouble();
        out.add(p);
        if (decades <= 2 && e < b.round()) {
          out.add(2 * p);
          out.add(5 * p);
        }
      }
    } else {
      for (var i = 0; i <= 5; i++) {
        out.add(a + (b - a) * i / 5);
      }
    }
    return out;
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.xs, this.color, this.threshold, this.thresholdColor);
  final List<double> xs;
  final Color color;
  final double? threshold;
  final Color thresholdColor;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final x in xs) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    final t = threshold;
    if (t != null) {
      final q = Paint()
        ..color = thresholdColor
        ..strokeWidth = 2;
      for (double y = 0; y < size.height; y += 8) {
        canvas.drawLine(Offset(t, y), Offset(t, math.min(y + 4, size.height)), q);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.xs != xs || old.color != color || old.threshold != threshold;
}

class HBarChart extends StatelessWidget {
  const HBarChart({
    super.key,
    required this.series,
    required this.groups,
    required this.format,
    this.log = true,
    this.labelWidth = 200,
    this.barHeight = 14,
    this.threshold,
    this.thresholdLabel,
    this.axisTitle,
    this.showLegend = true,
  });

  final List<ChartSeries> series;
  final List<ChartGroup> groups;
  final String Function(double) format;
  final bool log;
  final double labelWidth;
  final double barHeight;
  final double? threshold;
  final String? thresholdLabel;
  final String? axisTitle;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall ?? const TextStyle(fontSize: 11);
    final values = <double>[];
    for (final g in groups) {
      for (final b in g.bars) {
        if (!b.value.isFinite) continue;
        if (log && b.value <= 0) continue;
        values.add(b.value);
        if (b.lo != null && b.lo!.isFinite && (!log || b.lo! > 0)) values.add(b.lo!);
        if (b.hi != null && b.hi!.isFinite) values.add(b.hi!);
      }
    }
    if (threshold != null) values.add(threshold!);
    if (values.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No data for this selection.'),
      );
    }
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);

    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : 900.0;
      const valueW = 92.0;
      final plotW = math.max(120.0, width - labelWidth - valueW);
      final scale = _Scale(minV, maxV, log, plotW);
      final ticks = scale.ticks();
      final tickXs = ticks.map((t) => labelWidth + scale.x(t)).toList();
      final thrX = threshold == null ? null : labelWidth + scale.x(threshold!);

      Widget barRow(ChartBar b) {
        final color = b.color ?? series[b.series].color;
        final w = math.max(1.5, scale.x(b.value));
        final lo = b.lo, hi = b.hi;
        final bar = Container(
          width: w,
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)),
          ),
        );
        return SizedBox(
          height: barHeight + 3,
          child: Row(
            children: [
              SizedBox(
                width: plotW,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      top: 1.5,
                      bottom: 1.5,
                      child: b.tooltip == null
                          ? bar
                          : Tooltip(
                              message: b.tooltip!,
                              waitDuration: const Duration(milliseconds: 250),
                              child: bar,
                            ),
                    ),
                    if (lo != null && hi != null && hi > lo)
                      Positioned(
                        left: scale.x(lo),
                        width: math.max(1.0, scale.x(hi) - scale.x(lo)),
                        top: (barHeight + 3) / 2 - 0.75,
                        height: 1.5,
                        child: IgnorePointer(child: Container(color: cs.onSurface)),
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: valueW,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(format(b.value), style: small, overflow: TextOverflow.fade, softWrap: false),
                ),
              ),
            ],
          ),
        );
      }

      final rows = <Widget>[];
      for (var gi = 0; gi < groups.length; gi++) {
        final g = groups[gi];
        if (g.bars.isEmpty) continue;
        rows.add(Container(
          color: gi.isEven ? cs.primary.withAlpha(10) : null,
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: labelWidth,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    g.label,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: g.bars.map(barRow).toList(),
              ),
            ],
          ),
        ));
      }

      final axis = SizedBox(
        width: labelWidth + plotW + valueW,
        height: 20,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < ticks.length; i++)
              Positioned(
                left: tickXs[i] - 40,
                width: 80,
                top: 2,
                child: Text(format(ticks[i]), textAlign: TextAlign.center, style: small),
              ),
          ],
        ),
      );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLegend && series.length > 1)
            Padding(
              padding: EdgeInsets.only(left: labelWidth, bottom: 8),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final s in series)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2)),
                      ),
                      const SizedBox(width: 6),
                      Text(s.name, style: small),
                    ]),
                ],
              ),
            ),
          axis,
          Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GridPainter(tickXs, cs.outlineVariant, thrX, cs.error),
                  ),
                ),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: labelWidth, top: 6),
            child: Text(
              [
                if (axisTitle != null) axisTitle!,
                log ? 'log scale' : 'linear scale',
                if (threshold != null && thresholdLabel != null) 'dashed line: ${thresholdLabel!}',
                if (groups.any((g) => g.bars.any((b) => b.lo != null))) 'whiskers: interquartile range',
              ].join(' · '),
              style: small.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      );
    });
  }
}
