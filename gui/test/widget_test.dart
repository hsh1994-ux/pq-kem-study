// Smoke tests: every page builds and lays out without errors, using the real
// files in ../results/raw when present (run `flutter test` in gui/).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pq_results/src/data.dart';
import 'package:pq_results/src/runner.dart';
import 'package:pq_results/src/pages/compare.dart';
import 'package:pq_results/src/pages/correctness.dart';
import 'package:pq_results/src/pages/files.dart';
import 'package:pq_results/src/pages/overview.dart';
import 'package:pq_results/src/pages/performance.dart';
import 'package:pq_results/src/pages/run.dart';
import 'package:pq_results/src/pages/sizes.dart';
import 'package:pq_results/src/pages/timing.dart';
import 'package:pq_results/src/pages/tls.dart';

void main() {
  late ResultsRepo repo;

  setUpAll(() async {
    final dir = '..${Platform.pathSeparator}results${Platform.pathSeparator}raw';
    repo = await ResultsRepo.load(dir);
  });

  final pages = <String, Widget Function(ResultsRepo)>{
    'overview': (r) => OverviewPage(repo: r),
    'run': (r) => RunPage(repo: r, runner: Runner()),
    'performance': (r) => PerformancePage(repo: r),
    'compare': (r) => ComparePage(repo: r),
    'sizes': (r) => SizesPage(repo: r),
    'tls': (r) => TlsPage(repo: r),
    'timing': (r) => TimingPage(repo: r),
    'correctness': (r) => CorrectnessPage(repo: r),
    'files': (r) => FilesPage(repo: r),
  };

  for (final size in const [Size(1600, 1000), Size(900, 700)]) {
    for (final e in pages.entries) {
      testWidgets('${e.key} page builds at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: e.value(repo))));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('performance page: switch operation and metric', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PerformancePage(repo: repo))));
    if (repo.of('e1').isEmpty) return;
    await tester.tap(find.text('decaps').first);
    await tester.pump();
    await tester.tap(find.text('Core cycles (est.)'));
    await tester.pump();
    await tester.tap(find.text('Timer ticks'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
