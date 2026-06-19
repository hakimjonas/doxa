/// Profiling: parse vs elab vs check breakdown, plus eval/conv stress.

import 'dart:developer';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'dart:io';
import 'dart:math';

const _prelude = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

void main() {
  // Seed prelude
  var b = <TopBinding>[], d = <DataDecl>[];
  for (final decl in _parse(_prelude).decls) {
    final prod = elabDecl(TopEnv(b, d), decl);
    final rd = [...d, ...prod.dataDecls];
    b = [...b, ...checkDeclResult(TopEnv(b, rd), prod)];
    d = rd;
  }

  profileStdlib(b, d);
  profileChurch(b, d, 500);
  profileEvalStress();
}

void profileStdlib(List<TopBinding> bindings, List<DataDecl> dataDecls) {
  final src = File('lib/stdlib/proofs.doxa').readAsStringSync();
  final prog = _parse(src);
  
  final sw = Stopwatch();
  
  // Warmup
  _check(prog, bindings, dataDecls);
  
  // Timed — 5 runs
  var parseUs = 0, elabUs = 0, checkUs = 0;
  const n = 5;
  for (var r = 0; r < n; r++) {
    // Re-parse every iteration (avoids caching)
    sw.reset(); sw.start();
    final p = _parse(src);
    sw.stop(); parseUs += sw.elapsedMicroseconds;
    
    var b = bindings.toList(), d = dataDecls.toList();
    var elabAcc = 0, checkAcc = 0;
    for (final decl in p.decls) {
      sw.reset(); sw.start();
      final prod = elabDecl(TopEnv(b, d), decl);
      sw.stop(); elabAcc += sw.elapsedMicroseconds;
      
      sw.reset(); sw.start();
      final rd = [...d, ...prod.dataDecls];
      final fin = checkDeclResult(TopEnv(b, rd), prod);
      sw.stop(); checkAcc += sw.elapsedMicroseconds;
      b = [...b, ...fin]; d = rd;
    }
    elabUs += elabAcc; checkUs += checkAcc;
  }
  
  print('stdlib/proofs (42 decls, avg $n runs, Dart JIT):');
  print('  parse: ${(parseUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*parseUs/(parseUs+elabUs+checkUs)).toStringAsFixed(0)}%)');
  print('  elab:  ${(elabUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*elabUs/(parseUs+elabUs+checkUs)).toStringAsFixed(0)}%)');
  print('  check: ${(checkUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*checkUs/(parseUs+elabUs+checkUs)).toStringAsFixed(0)}%)');
  print('');
}

void profileChurch(List<TopBinding> bindings, List<DataDecl> dataDecls, int depth) {
  final src = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
val id : Nat -> Nat = (x: Nat) => x
val chain : Nat = ${List.filled(depth, 'id(').join() + 'zero' + List.filled(depth, ')').join()}
''';
  
  final sw = Stopwatch();
  final prog = _parse(src);
  _check(prog, bindings, dataDecls);
  
  var parseUs = 0, elabUs = 0, checkUs = 0;
  const n = 3;
  for (var r = 0; r < n; r++) {
    sw.reset(); sw.start();
    final p = _parse(src);
    sw.stop(); parseUs += sw.elapsedMicroseconds;
    
    var b = bindings.toList(), d = dataDecls.toList();
    var elabAcc = 0, checkAcc = 0;
    for (final decl in p.decls) {
      sw.reset(); sw.start();
      final prod = elabDecl(TopEnv(b, d), decl);
      sw.stop(); elabAcc += sw.elapsedMicroseconds;
      
      sw.reset(); sw.start();
      final rd = [...d, ...prod.dataDecls];
      final fin = checkDeclResult(TopEnv(b, rd), prod);
      sw.stop(); checkAcc += sw.elapsedMicroseconds;
      b = [...b, ...fin]; d = rd;
    }
    elabUs += elabAcc; checkUs += checkAcc;
  }
  
  final total = parseUs + elabUs + checkUs;
  print('church_depth_$depth (avg $n runs, Dart JIT):');
  print('  parse: ${(parseUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*parseUs/total).toStringAsFixed(0)}%)');
  print('  elab:  ${(elabUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*elabUs/total).toStringAsFixed(0)}%)');
  print('  check: ${(checkUs~/n/1000).toStringAsFixed(2)}ms (${(100.0*checkUs/total).toStringAsFixed(0)}%)');
  print('');
}

void profileEvalStress() {
  // Build an eval chain: eval deep TApp of identity on TType(0)
  // to measure pure β-reduction without elaborator overhead.
  Term chain(int n) {
    Term t = const TType(0);
    const id = TLam(TType(0), TBound(0));
    for (var i = 0; i < n; i++) {
      t = TApp(id, t);
    }
    return t;
  }
  
  final env = ENil();
  const n = 10;
  for (final depth in [100, 500, 1000, 5000]) {
    final t = chain(depth);
    final sw = Stopwatch();
    // Warmup
    eval(t, env);
    var us = 0;
    for (var i = 0; i < n; i++) {
      sw.reset(); sw.start();
      eval(t, env);
      sw.stop(); us += sw.elapsedMicroseconds;
    }
    print('eval deep TApp chain depth=$depth (avg ${n} runs): ${(us~/n/1000).toStringAsFixed(2)}ms');
  }
  print('');
  
  // Conv stress: compare two deep Pi chains
  for (final depth in [100, 500, 1000, 5000]) {
    Value deepPi(int n) {
      Value v = VType(0);
      for (var i = 0; i < n; i++) {
        final body = TType(0);
        v = VPi(VType(0), Closure(ENil(), body));
      }
      return v;
    }
    final a = deepPi(depth);
    final b = deepPi(depth);
    final sw = Stopwatch();
    conv(0, a, b); // warmup
    var us = 0;
    for (var i = 0; i < n; i++) {
      sw.reset(); sw.start();
      conv(0, a, b);
      sw.stop(); us += sw.elapsedMicroseconds;
    }
    print('conv deep Pi chain depth=$depth (avg ${n} runs): ${(us~/n/1000).toStringAsFixed(2)}ms');
  }
}

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed');
}

void _check(SProgram prog, List<TopBinding> bindings, List<DataDecl> dataDecls) {
  var b = bindings.toList(), d = dataDecls.toList();
  for (final decl in prog.decls) {
    final prod = elabDecl(TopEnv(b, d), decl);
    final rd = [...d, ...prod.dataDecls];
    b = [...b, ...checkDeclResult(TopEnv(b, rd), prod)];
    d = rd;
  }
}
