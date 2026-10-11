// Loading results/raw/*.csv: '# key=value' metadata lines, then a CSV table.
//
// Only dart:io is used (no plugins), so the app builds the same way on
// macOS, Windows and Linux, on x86-64 and ARM64.
import 'dart:io';

/// Minimal RFC 4180 CSV parser (quoted fields, doubled quotes, CRLF).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var fieldStarted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
      fieldStarted = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
      fieldStarted = true;
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      if (fieldStarted || field.isNotEmpty || row.isNotEmpty) {
        row.add(field.toString());
        rows.add(row);
      }
      field.clear();
      row = <String>[];
      fieldStarted = false;
    } else {
      field.write(c);
      fieldStarted = true;
    }
  }
  if (fieldStarted || field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

double? numOf(Map<String, String> row, String col) {
  final v = row[col];
  if (v == null || v.isEmpty) return null;
  return double.tryParse(v);
}

/// "11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz" -> "Intel Core i7-1185G7".
String shortCpu(String cpu) {
  var s = cpu.replaceAll(RegExp(r'\((R|TM|tm|r)\)'), '');
  s = s.replaceAll(RegExp(r'\s*@.*$'), '');
  s = s.replaceAll(RegExp(r'^\d+(st|nd|rd|th) Gen\s+'), '');
  s = s.replaceAll(RegExp(r'\s+Processor\b'), '');
  s = s.replaceAll(RegExp(r'\s+CPU\b'), '');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return s.isEmpty ? cpu : s;
}

final _nameRe = RegExp(r'^(e\d+[a-z]*)_(.+)_(\d{8})-(\d{6})(_quick)?\.csv$');

class ResultFile {
  ResultFile({
    required this.path,
    required this.name,
    required this.experiment,
    required this.arch,
    required this.time,
    required this.quick,
    required this.meta,
    required this.columns,
    required this.rows,
  });

  final String path;
  final String name;

  /// e1, e2, e3dudect, e3divscan, e3valgrind, e4
  final String experiment;
  final String arch;
  final DateTime? time;
  final bool quick;
  final Map<String, String> meta;
  final List<String> columns;
  final List<Map<String, String>> rows;

  String get cpu => meta['cpu'] ?? arch;
  String get host => meta['host'] ?? '';
  String get virt => meta['virtualisation'] ?? '';

  /// Files from the same machine share this key. Not the host name: Docker
  /// gives every container a random one.
  String get machineKey => '$cpu|$arch';
  String get machineLabel => '${shortCpu(cpu)} ($arch)';

  String get timeLabel {
    final t = time;
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  String get label => '$machineLabel · $timeLabel${quick ? ' · quick' : ''}';

  bool has(String col) => columns.contains(col);

  static ResultFile? parse(String path, String text) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final m = _nameRe.firstMatch(name);
    if (m == null) return null;
    final d = m.group(3)!, t = m.group(4)!;
    final time = DateTime(int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)),
        int.parse(d.substring(6, 8)), int.parse(t.substring(0, 2)), int.parse(t.substring(2, 4)),
        int.parse(t.substring(4, 6)));
    final meta = <String, String>{};
    final body = StringBuffer();
    for (final line in text.split('\n')) {
      if (line.startsWith('#')) {
        final kv = line.substring(1).trim();
        final eq = kv.indexOf('=');
        if (eq > 0) meta[kv.substring(0, eq).trim()] = kv.substring(eq + 1).trim();
      } else {
        body.writeln(line);
      }
    }
    final table = parseCsv(body.toString());
    if (table.isEmpty) return null;
    final cols = table.first.map((c) => c.trim()).toList();
    final rows = <Map<String, String>>[];
    for (final r in table.skip(1)) {
      if (r.length == 1 && r.first.trim().isEmpty) continue;
      final map = <String, String>{};
      for (var i = 0; i < cols.length; i++) {
        map[cols[i]] = i < r.length ? r[i] : '';
      }
      rows.add(map);
    }
    return ResultFile(
      path: path,
      name: name,
      experiment: m.group(1)!,
      arch: m.group(2)!,
      time: time,
      quick: m.group(5) != null,
      meta: meta,
      columns: cols,
      rows: rows,
    );
  }
}

/// KEM order and NIST level, from kems.conf when it is found next to results/.
class KemCatalog {
  KemCatalog(this.order, this.level);

  final List<String> order;
  final Map<String, int> level;

  // X25519 = X25519-DHKEM in runs made before the plain-ECDH baseline was added.
  static const baselines = ['X25519-ECDH', 'X25519-DHKEM', 'X25519', 'X25519MLKEM768'];

  static final fallback = KemCatalog([
    'ML-KEM-512', 'HQC-1', 'FrodoKEM-640-SHAKE', 'Classic-McEliece-348864', //
    'ML-KEM-768', 'HQC-3', 'FrodoKEM-976-SHAKE', 'Classic-McEliece-460896',
    'ML-KEM-1024', 'HQC-5', 'FrodoKEM-1344-SHAKE', 'Classic-McEliece-6688128',
  ], {
    'ML-KEM-512': 1, 'HQC-1': 1, 'FrodoKEM-640-SHAKE': 1, 'Classic-McEliece-348864': 1, //
    'ML-KEM-768': 3, 'HQC-3': 3, 'FrodoKEM-976-SHAKE': 3, 'Classic-McEliece-460896': 3,
    'ML-KEM-1024': 5, 'HQC-5': 5, 'FrodoKEM-1344-SHAKE': 5, 'Classic-McEliece-6688128': 5,
  });

  static KemCatalog parse(String text) {
    final order = <String>[];
    final level = <String, int>{};
    var current = 0;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        final m = RegExp(r'level\s+(\d)', caseSensitive: false).firstMatch(line);
        if (m != null) current = int.parse(m.group(1)!);
        continue;
      }
      order.add(line);
      level[line] = current;
    }
    return order.isEmpty ? fallback : KemCatalog(order, level);
  }

  /// Baselines first, then kems.conf order, then anything else alphabetically.
  List<String> sort(Iterable<String> algs) {
    final all = algs.toSet().toList();
    int rank(String a) {
      final b = baselines.indexOf(a);
      if (b >= 0) return b;
      final i = order.indexOf(a);
      return i >= 0 ? 10 + i : 1000;
    }

    all.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.compareTo(b);
    });
    return all;
  }

  /// 0 = classical / hybrid baseline, otherwise the NIST level.
  int levelOf(String alg) {
    if (baselines.contains(alg)) return 0;
    final l = level[alg];
    if (l != null) return l;
    final m = RegExp(r'(512|768|1024)$').firstMatch(alg);
    if (m != null) return {'512': 1, '768': 3, '1024': 5}[m.group(1)]!;
    return -1;
  }
}

class ResultsRepo {
  ResultsRepo(this.dir, this.files, this.catalog, this.errors);

  final String dir;
  final List<ResultFile> files;
  final KemCatalog catalog;
  final List<String> errors;

  static final String sep = Platform.pathSeparator;

  /// The repository root (two levels above results/raw), if it looks like one.
  String get repoRoot => Directory(dir).parent.parent.path;

  static Future<ResultsRepo> load(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) {
      throw FileSystemException('Folder not found', dir);
    }
    final files = <ResultFile>[];
    final errors = <String>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File || !e.path.toLowerCase().endsWith('.csv')) continue;
      try {
        final f = ResultFile.parse(e.path, await e.readAsString());
        if (f != null) files.add(f);
      } catch (err) {
        errors.add('${e.path}: $err');
      }
    }
    files.sort((a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)));
    var catalog = KemCatalog.fallback;
    final conf = File('${d.parent.parent.path}${sep}kems.conf');
    try {
      if (await conf.exists()) catalog = KemCatalog.parse(await conf.readAsString());
    } catch (_) {}
    return ResultsRepo(dir, files, catalog, errors);
  }

  /// Files of one experiment, newest first.
  List<ResultFile> of(String experiment, {bool includeQuick = true}) => files
      .where((f) => f.experiment == experiment && (includeQuick || !f.quick))
      .toList();

  /// Newest non-quick file of an experiment for every machine (falls back to
  /// quick files when a machine has nothing else).
  List<ResultFile> latestPerMachine(String experiment) {
    final out = <String, ResultFile>{};
    for (final f in of(experiment)) {
      final cur = out[f.machineKey];
      if (cur == null || (cur.quick && !f.quick)) out[f.machineKey] = f;
    }
    return out.values.toList();
  }

  ResultFile? byName(String name) {
    for (final f in files) {
      if (f.name == name) return f;
    }
    return null;
  }

  /// Machines seen in any file, in a stable order.
  Map<String, List<ResultFile>> byMachine() {
    final out = <String, List<ResultFile>>{};
    for (final f in files) {
      out.putIfAbsent(f.machineKey, () => []).add(f);
    }
    return out;
  }
}

/// Where to look for results/raw when the app starts.
String? findResultsDir() {
  final sep = Platform.pathSeparator;
  final env = Platform.environment['PQ_RESULTS'];
  if (env != null && Directory(env).existsSync()) return env;
  final starts = <String>[Directory.current.path];
  try {
    starts.add(File(Platform.resolvedExecutable).parent.path);
  } catch (_) {}
  for (final s in starts) {
    var d = Directory(s);
    for (var i = 0; i < 14; i++) {
      final cand = Directory('${d.path}${sep}results${sep}raw');
      try {
        if (cand.existsSync()) return cand.path;
      } catch (_) {}
      final parent = d.parent;
      if (parent.path == d.path) break;
      d = parent;
    }
  }
  return null;
}

/// Remembers the last folder in a small text file in the user's home.
class Settings {
  static File? _file() {
    final env = Platform.environment;
    final base = Platform.isWindows ? env['APPDATA'] : env['HOME'];
    if (base == null || base.isEmpty) return null;
    return File('$base${Platform.pathSeparator}.pq_results_viewer');
  }

  static String? loadDir() {
    try {
      final f = _file();
      if (f == null || !f.existsSync()) return null;
      final s = f.readAsStringSync().trim();
      return s.isNotEmpty && Directory(s).existsSync() ? s : null;
    } catch (_) {
      return null;
    }
  }

  static void saveDir(String dir) {
    try {
      _file()?.writeAsStringSync(dir);
    } catch (_) {}
  }
}
