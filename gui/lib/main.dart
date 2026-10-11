// PQ-KEM results viewer: a desktop app (macOS, Windows, Linux; x86-64 and
// ARM64) that shows everything the study writes to results/raw.
//
// It finds results/raw automatically when started from inside the repository
// (`flutter run` in gui/, or the built app inside gui/build/...), remembers a
// folder you pick, and reloads by itself when new results files appear.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/data.dart';
import 'src/runner.dart';
import 'src/pages/compare.dart';
import 'src/pages/correctness.dart';
import 'src/pages/files.dart';
import 'src/pages/overview.dart';
import 'src/pages/performance.dart';
import 'src/pages/run.dart';
import 'src/pages/sizes.dart';
import 'src/pages/timing.dart';
import 'src/pages/tls.dart';

void main() => runApp(const PqResultsApp());

class PqResultsApp extends StatefulWidget {
  const PqResultsApp({super.key});

  @override
  State<PqResultsApp> createState() => _PqResultsAppState();
}

class _PqResultsAppState extends State<PqResultsApp> {
  ThemeMode _mode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PQ-KEM results',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      themeMode: _mode,
      home: HomePage(
        onToggleTheme: () => setState(() {
          final dark = _mode == ThemeMode.dark ||
              (_mode == ThemeMode.system &&
                  WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
          _mode = dark ? ThemeMode.light : ThemeMode.dark;
        }),
      ),
    );
  }
}

class _Dest {
  const _Dest(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const _dests = [
  _Dest('Overview', Icons.dashboard_outlined, Icons.dashboard),
  _Dest('Run', Icons.play_circle_outline, Icons.play_circle),
  _Dest('Performance', Icons.speed_outlined, Icons.speed),
  _Dest('Compare', Icons.compare_arrows_outlined, Icons.compare_arrows),
  _Dest('Sizes', Icons.straighten_outlined, Icons.straighten),
  _Dest('TLS', Icons.lan_outlined, Icons.lan),
  _Dest('Timing', Icons.timer_outlined, Icons.timer),
  _Dest('Correctness', Icons.verified_outlined, Icons.verified),
  _Dest('Files', Icons.folder_open_outlined, Icons.folder_open),
];

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onToggleTheme});
  final VoidCallback onToggleTheme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _dir;
  ResultsRepo? _repo;
  String? _error;
  bool _loading = false;
  int _index = 0;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;

  /// Lives here (not in the Run page) so a run keeps going while you browse.
  final Runner _runner = Runner();

  @override
  void initState() {
    super.initState();
    _runner.onFinished = () {
      if (mounted) unawaited(_load());
    };
    // The folder picked last time, else results/raw of the checkout the app runs from.
    final dir = Settings.loadDir() ?? findResultsDir();
    if (dir != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _setDir(dir, save: false));
    }
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    _runner.dispose();
    super.dispose();
  }

  void _setDir(String dir, {bool save = true}) {
    _dir = dir;
    if (save) Settings.saveDir(dir);
    _watch?.cancel();
    _watch = null;
    try {
      // Reload when a run writes a new CSV (debounced; not supported on some network shares).
      _watch = Directory(dir).watch().listen((e) {
        if (!e.path.toLowerCase().endsWith('.csv')) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(seconds: 1), _load);
      }, onError: (_) {});
    } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    final dir = _dir;
    if (dir == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = await ResultsRepo.load(dir);
      if (!mounted) return;
      setState(() {
        _repo = repo;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      var msg = '$e';
      if (Platform.isMacOS && msg.contains('Operation not permitted')) {
        msg += '\n\nmacOS blocked the read: the app sandbox is still on. Run gui/setup.sh once '
            '(it turns the sandbox off for this local tool) and start the app again.';
      }
      setState(() {
        _repo = null;
        _error = msg;
        _loading = false;
      });
    }
  }

  Future<void> _chooseFolder() async {
    final ctrl = TextEditingController(text: _dir ?? '');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Results folder'),
        content: SizedBox(
          width: 620,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Path to the repository\'s results/raw folder. Tips: on macOS, select the folder in '
                'Finder and press Option-Command-C to copy its path. On Windows, a WSL folder looks like '
                r'\\wsl.localhost\Ubuntu-24.04\home\<you>\pq-kem-study\results\raw'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Folder'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              final found = findResultsDir();
              if (found != null) ctrl.text = found;
            },
            child: const Text('Auto-detect'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text), child: const Text('Open')),
        ],
      ),
    );
    ctrl.dispose();
    if (picked == null) return;
    var p = picked.trim();
    if (p.length > 1 && p.startsWith('"') && p.endsWith('"')) p = p.substring(1, p.length - 1);
    if (p.isEmpty) return;
    // Accept the repository root too.
    final sep = Platform.pathSeparator;
    if (!Directory(p).existsSync() || Directory('$p${sep}results${sep}raw').existsSync()) {
      final inner = '$p${sep}results${sep}raw';
      if (Directory(inner).existsSync()) p = inner;
    }
    _setDir(p);
  }

  Widget _page(ResultsRepo repo, int i) {
    switch (i) {
      case 0:
        return OverviewPage(repo: repo);
      case 1:
        return RunPage(repo: repo, runner: _runner);
      case 2:
        return PerformancePage(repo: repo);
      case 3:
        return ComparePage(repo: repo);
      case 4:
        return SizesPage(repo: repo);
      case 5:
        return TlsPage(repo: repo);
      case 6:
        return TimingPage(repo: repo);
      case 7:
        return CorrectnessPage(repo: repo);
      default:
        return FilesPage(repo: repo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = _repo;
    Widget body;
    if (repo != null) {
      body = Row(children: [
        NavigationRail(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          labelType: NavigationRailLabelType.all,
          destinations: [
            for (final d in _dests)
              NavigationRailDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: Text(d.label)),
          ],
        ),
        const VerticalDivider(width: 1),
        // IndexedStack keeps each page's selections while switching tabs.
        Expanded(
          child: IndexedStack(
            index: _index,
            children: [for (var i = 0; i < _dests.length; i++) _page(repo, i)],
          ),
        ),
      ]);
    } else if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_off_outlined, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(_error == null ? 'No results folder found' : 'Could not open the results folder',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              _error ??
                  'Start the app from inside the pq-kem-study repository, or choose its results/raw folder.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _chooseFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose folder'),
            ),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Post-quantum KEM study · results'),
          if (_dir != null)
            Text(_dir!, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
        ]),
        actions: [
          if (_loading && repo != null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(tooltip: 'Reload', onPressed: _dir == null ? null : _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: 'Choose results folder', onPressed: _chooseFolder, icon: const Icon(Icons.folder_open)),
          IconButton(tooltip: 'Light / dark', onPressed: widget.onToggleTheme, icon: const Icon(Icons.brightness_6)),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }
}
