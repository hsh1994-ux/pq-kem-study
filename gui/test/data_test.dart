// Unit tests for CSV loading and formatting: `flutter test` (run in gui/).
import 'package:flutter_test/flutter_test.dart';
import 'package:pq_results/src/data.dart';
import 'package:pq_results/src/e1.dart';
import 'package:pq_results/src/format.dart';

const _e1 = '''# date=2026-10-11T11:27:29Z
# host=hsh
# arch=x86_64
# cpu=11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz
# virtualisation=wsl in WSL2
tier,alg,op,n,unit,ns_per_tick,min,p25,median,p75,mean,median_ns,p25_ns,p75_ns,stack_bytes,pk_bytes,sk_bytes,ct_bytes,ss_bytes,ghz_before,ghz_after,median_core_cycles_est
opt,ML-KEM-768,keygen,1000,tsc_cycles,0.540048,15495,15589,15620,15657,15856.8,8435.5,8418.8,8455.5,11792,1184,2400,1088,32,4.700,4.800,40069
openssl,X25519,encaps,1000,tsc_cycles,0.540802,106600,107804,108057,108362,109912.5,58437.4,58300.6,58602.4,-1,32,-1,32,32,,,
''';

void main() {
  test('CSV parser handles quotes, doubled quotes and CRLF', () {
    final rows = parseCsv('a,b,c\r\n1,"x, y","say ""hi"""\r\n2,,\n');
    expect(rows.length, 3);
    expect(rows[1], ['1', 'x, y', 'say "hi"']);
    expect(rows[2], ['2', '', '']);
  });

  test('results file: name, metadata and rows', () {
    final f = ResultFile.parse('/r/results/raw/e1_x86_64_20261011-132729.csv', _e1)!;
    expect(f.experiment, 'e1');
    expect(f.arch, 'x86_64');
    expect(f.quick, isFalse);
    expect(f.time, DateTime(2026, 10, 11, 13, 27, 29));
    expect(f.meta['host'], 'hsh');
    expect(f.machineLabel, 'Intel Core i7-1185G7 (x86_64)');
    expect(f.rows.length, 2);
    expect(f.rows.first['alg'], 'ML-KEM-768');
    expect(f.rows.last['ghz_before'], '');
  });

  test('file names: quick runs and E3 sub-experiments', () {
    final q = ResultFile.parse('e1_aarch64_20261011-105929_quick.csv', _e1)!;
    expect(q.quick, isTrue);
    expect(q.arch, 'aarch64');
    final d = ResultFile.parse('e3dudect_x86_64_20260927-111739.csv', 'tier,target\nref,x\n')!;
    expect(d.experiment, 'e3dudect');
    expect(ResultFile.parse('notes.csv', 'a\n1\n'), isNull);
  });

  test('E1 metrics: time, estimated core cycles, missing estimate', () {
    final f = ResultFile.parse('e1_x86_64_20261011-132729.csv', _e1)!;
    final idx = E1Index(f);
    final row = idx.get('opt', 'ML-KEM-768', 'keygen')!;
    expect(e1Point(row, E1Metric.time)!.value, 8435.5);
    final c = e1Point(row, E1Metric.cycles)!;
    expect(c.value, 40069);
    expect(c.lo! < c.value && c.hi! > c.value, isTrue);
    // Runs from before the calibration update have no estimate.
    expect(e1Point(idx.get('openssl', 'X25519', 'encaps')!, E1Metric.cycles), isNull);
  });

  test('KEM catalog: order and levels from kems.conf', () {
    final cat = KemCatalog.parse('# NIST level 1\nML-KEM-512\nHQC-1\n# NIST level 3\nML-KEM-768\n');
    expect(cat.sort(['ML-KEM-768', 'X25519', 'HQC-1', 'Zzz', 'ML-KEM-512']),
        ['X25519', 'ML-KEM-512', 'HQC-1', 'ML-KEM-768', 'Zzz']);
    expect(cat.sort(['X25519MLKEM768', 'X25519-DHKEM', 'X25519-ECDH']), ['X25519-ECDH', 'X25519-DHKEM', 'X25519MLKEM768']);
    expect(cat.levelOf('X25519-ECDH'), 0);
    expect(cat.levelOf('ML-KEM-768'), 3);
    expect(cat.levelOf('X25519MLKEM768'), 0);
    expect(cat.levelOf('ML-KEM-1024'), 5);
  });

  test('formatting', () {
    expect(fmtNs(812), '812 ns');
    expect(fmtNs(8436), '8.44 µs');
    expect(fmtNs(31059217), '31.1 ms');
    expect(fmtCount(57395037), '57.4M');
    expect(groupDigits(261120), '261,120');
    expect(fmtRatio(3.2149), '3.21×');
  });
}
