import 'dart:io';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

void main() {
  // Profile: parse-only, no elaboration, no checking.
  final files = {
    'stdlib/nat': 'lib/stdlib/nat.doxa',
    'stdlib/bool': 'lib/stdlib/bool.doxa',
    'stdlib/option': 'lib/stdlib/option.doxa',
    'stdlib/vec': 'lib/stdlib/vec.doxa',
    'stdlib/list': 'lib/stdlib/list.doxa',
    'stdlib/eq': 'lib/stdlib/eq.doxa',
    'stdlib/proofs': 'lib/stdlib/proofs.doxa',
    'example/proofs': 'example/proofs.doxa',
  };
  
  final sw = Stopwatch();
  const warmup = 3, n = 10;
  
  print('=== Parser-only profiling ($n runs, best of ${n}) ===');
  print('File           | Size     | Best (us) | Median (us) | Parse rate');
  print('---------------|----------|-----------|-------------|-----------');
  
  for (final entry in files.entries) {
    final path = entry.value;
    final name = entry.key;
    if (!File(path).existsSync()) continue;
    final src = File(path).readAsStringSync();
    
    // Warmup
    for (var i = 0; i < warmup; i++) parseProgram(src);
    
    final times = <int>[];
    for (var i = 0; i < n; i++) {
      sw.reset(); sw.start();
      parseProgram(src);
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    final best = times.first;
    final median = times[n ~/ 2];
    final bytes = src.length;
    final rate = (bytes / (best / 1000000)).toStringAsFixed(1);
    final sizeStr = bytes >= 1024
        ? '${(bytes/1024).toStringAsFixed(1)} KB'
        : '$bytes B';
    print('${name.padRight(15)} | ${sizeStr.padLeft(8)} | ${best.toString().padLeft(9)} | ${median.toString().padLeft(11)} | $rate B/s');
  }
  
  // Parse expr vs parse program comparison
  print('');
  print('=== parseExpr vs parseProgram (example/proofs first 10 lines) ===');
  final exampleSrc = File('example/proofs.doxa').readAsStringSync();
  final lines = exampleSrc.split('\n').take(20).where((l) => l.trim().isNotEmpty && !l.trim().startsWith('//')).toList();
  print('File           | parseProgram | parseExpr (best of $n)');
  print('---------------|--------------|--------------');
  for (final line in lines.take(10)) {
    final lineSrc = line.trim();
    if (lineSrc.isEmpty) continue;
    
    // parseProgram
    for (var i = 0; i < warmup; i++) parseProgram(lineSrc);
    sw.reset(); sw.start();
    parseProgram(lineSrc);
    sw.stop();
    final progUs = sw.elapsedMicroseconds;
    
    // parseExpr
    for (var i = 0; i < warmup; i++) parseExpr(lineSrc);
    sw.reset(); sw.start();
    parseExpr(lineSrc);
    sw.stop();
    final exprUs = sw.elapsedMicroseconds;
    
    final display = lineSrc.length > 40 ? '${lineSrc.substring(0, 40)}...' : lineSrc;
    print('${display.padRight(15)} | ${progUs.toString().padLeft(12)} | ${exprUs.toString().padLeft(12)}');
  }
}
