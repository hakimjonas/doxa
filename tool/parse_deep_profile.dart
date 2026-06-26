/// Deeper parser profiling: breaks down parseProgram into observable phases.
/// Measures: (1) combinator overhead via parseProgram vs hand-parsed,
/// (2) AST node count and allocation churn, (3) lexeme vs combinator ratio.

import 'dart:io';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

void main() {
  final path = 'lib/stdlib/proofs.doxa';
  final src = File(path).readAsStringSync();
  final lines = src.length;
  final decls = 'val fun type data'.allMatches(src).length;

  print('=== Source stats ===');
  print('$path');
  print('  raw bytes: $lines');
  print('  approximate decl count: $decls');
  print('');

  // Profile: parseProgram with AST construction vs parse-only (discard)
  final sw = Stopwatch();
  const warmup = 5, n = 10;

  // Warmup
  for (var i = 0; i < warmup; i++) parseProgram(src);

  print('=== Parse + AST construction (parseProgram) ===');
  print('Run  |  Time (us)');
  print('-----|------------');
  final times = <int>[];
  for (var i = 0; i < n; i++) {
    sw.reset();
    sw.start();
    final r = parseProgram(src);
    sw.stop();
    final us = sw.elapsedMicroseconds;
    times.add(us);
    final declCount =
        r is Success<ParseError, SProgram>
            ? r.value.decls.length
            : (r is Partial<ParseError, SProgram> ? r.value.decls.length : '?');
    print(
      '  ${(i + 1).toString().padLeft(2)} | ${us.toString().padLeft(10)}  (${declCount} decls)',
    );
  }
  times.sort();
  final best = times.first;
  final median = times[n ~/ 2];
  final worst = times.last;
  print('best: $best us');
  print('median: $median us');
  print('worst: $worst us');
  print('parse rate: ${(lines / (best / 1000000)).toStringAsFixed(1)} B/s');
  print('');

  // Profile: measure parseProgram once, then count AST nodes
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) {
    var exprCount = 0;
    var spanBytes = 0;
    var strBytes = 0;

    void walk(dynamic node, int depth) {
      if (node is SProgram) {
        for (final d in node.decls) walk(d, depth + 1);
      } else if (node is SDecl) {
        exprCount++;
        walk(node.kind, depth + 1);
      } else if (node is SExpr) {
        exprCount++;
        walk(node.kind, depth + 1);
      } else {
        // Leaf: SExprKind, DoxaSpan, String, etc.
      }
    }

    walk(r.value, 0);

    print('=== AST node estimate ===');
    print('declS + exprs traversed: ~$exprCount');
    print('best parse per node: ${(best / exprCount).toStringAsFixed(2)} us');
    print('');
  }

  // Profile: tokenize only (lexer phase, no combinator dispatch)
  // Use the existing parse pipeline but measure the internal lexer.
  // The parser uses _lex() which wraps _ws and captures text.
  // We can approximate lex time by parsing a whitespace-only variant.

  // Actually, the simplest way to measure lexer overhead:
  // The parser uses _lex() which does: rawPar.thenSkip(_ws)
  // We can measure _ws itself.
  // But _ws is private. Instead, parse a program that is pure whitespace.
  final whitespaceSrc = src.replaceAll(RegExp(r'[^\s]'), ' ');
  for (var i = 0; i < warmup; i++) parseProgram(whitespaceSrc);
  sw.reset();
  sw.start();
  parseProgram(whitespaceSrc);
  sw.stop();
  final wsUs = sw.elapsedMicroseconds;
  print('=== Lexer-only (whitespace approximation) ===');
  print('whitespace parse: $wsUs us');
  print(
    'lexer fraction: ${(100.0 * wsUs / best).toStringAsFixed(1)}% of total parse',
  );
  print('');

  // Profile: parseProgram on a minimal file vs full stdlib
  final tiny = 'val x : Type = Type';
  for (var i = 0; i < warmup; i++) parseProgram(tiny);
  sw.reset();
  sw.start();
  parseProgram(tiny);
  sw.stop();
  final tinyUs = sw.elapsedMicroseconds;
  print('=== Tiny file (18 bytes) ===');
  print('parse: $tinyUs us');
  print(
    'fixed overhead: likely $tinyUs us per file (parser init, trampoline setup)',
  );

  // Profile: repeated parse of the same decl, varying decl count
  print('');
  print('=== Scaling: repeated val x = Type ===');
  for (final n in [1, 10, 50, 100, 200]) {
    final repeated = List.filled(n, 'val x$n : Type = Type\n').join();
    for (var i = 0; i < warmup ~/ 2; i++) parseProgram(repeated);
    sw.reset();
    sw.start();
    parseProgram(repeated);
    sw.stop();
    final us = sw.elapsedMicroseconds;
    final perDecl = (us / n).toStringAsFixed(1);
    print(
      '  ${n.toString().padLeft(4)} decls | ${us.toString().padLeft(8)} us  (${perDecl.padLeft(6)} us/decl)',
    );
  }
}
