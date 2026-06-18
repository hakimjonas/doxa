/// Quick parse-throughput benchmark over the .doxa corpus.
///
/// Times `parseProgram` on every program in lib/stdlib + test/programs.
/// Not a rigorous microbenchmark, a baseline number to compare the
/// rule()-based parser against a future Pratt variant, and to sanity
/// the cost before a WASM build. Run: `dart run tool/parse_bench.dart`.
library;

import 'dart:io';

import 'package:doxa/src/parse.dart';
import 'package:rumil/rumil.dart';

void main() {
  final files =
      <File>[
          ...Directory(
            'lib/stdlib',
          ).listSync(recursive: true).whereType<File>(),
          ...Directory(
            'doxa_tooling/test/programs',
          ).listSync(recursive: true).whereType<File>(),
        ].where((f) => f.path.endsWith('.doxa')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final sources = files.map((f) => f.readAsStringSync()).toList();
  final totalBytes = sources.fold<int>(0, (a, s) => a + s.length);

  // Warm up the JIT / parser caches.
  for (var i = 0; i < 50; i++) {
    for (final s in sources) {
      parseProgram(s);
    }
  }

  const reps = 200;
  final sw = Stopwatch()..start();
  var ok = 0;
  for (var i = 0; i < reps; i++) {
    for (final s in sources) {
      final r = parseProgram(s);
      if (r is Success<ParseError, Object?> ||
          r is Partial<ParseError, Object?>)
        ok++;
    }
  }
  sw.stop();

  final totalParses = reps * sources.length;
  final usPerParse = sw.elapsedMicroseconds / totalParses;
  final mbPerSec =
      (totalBytes * reps) / sw.elapsedMicroseconds; // bytes/us == MB/s

  stdout.writeln('files:        ${files.length}');
  stdout.writeln('corpus bytes: $totalBytes');
  stdout.writeln('parses:       $totalParses  (ok/partial: $ok)');
  stdout.writeln('total time:   ${sw.elapsedMilliseconds} ms');
  stdout.writeln('per parse:    ${usPerParse.toStringAsFixed(1)} us');
  stdout.writeln('throughput:   ${mbPerSec.toStringAsFixed(1)} MB/s');
}
