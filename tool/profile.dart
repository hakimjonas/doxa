/// Quick profiling: run stdlib proofs and church depth 500 with breakdown.

import 'dart:developer';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';

const prelude = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}
''';

void main() {
  // Load prelude
  var bindings = <TopBinding>[];
  var dataDecls = <DataDecl>[];
  for (final decl in (parseProgram(prelude).value as SProgram).decls) {
    final p = elabDecl(TopEnv(bindings, dataDecls), decl);
    final rd = [...dataDecls, ...p.dataDecls];
    bindings = [...bindings, ...checkDeclResult(TopEnv(bindings, rd), p)];
    dataDecls = rd;
  }

  // stdlib proofs
  final src = _read('lib/stdlib/proofs.doxa');
  final sw = Stopwatch();
  var totalParse = 0, totalElab = 0, totalCheck = 0, totalNf = 0;

  // Warmup
  _check(src, bindings, dataDecls);

  // Timed run
  for (var i = 0; i < 3; i++) {
    sw.reset(); sw.start();
    final prog = parseProgram(src).value as SProgram;
    sw.stop(); totalParse += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList();
    var elabUs = 0, checkUs = 0;

    for (final decl in prog.decls) {
      sw.reset(); sw.start();
      final produced = elabDecl(TopEnv(b, d), decl);
      sw.stop(); elabUs += sw.elapsedMicroseconds;

      sw.reset(); sw.start();
      final rd = [...d, ...produced.dataDecls];
      final finalized = checkDeclResult(TopEnv(b, rd), produced);
      sw.stop(); checkUs += sw.elapsedMicroseconds;
      b = [...b, ...finalized];
      d = rd;
    }
    totalElab += elabUs;
    totalCheck += checkUs;
  }

  // Average
  final n = 3;
  print('=== stdlib/proofs (average of $n runs) ===');
  print('parse:  ${(totalParse~/n/1000).toStringAsFixed(2)}ms');
  print('elab:   ${(totalElab~/n/1000).toStringAsFixed(2)}ms');
  print('check:  ${(totalCheck~/n/1000).toStringAsFixed(2)}ms');
  print('total:  ${((totalParse+totalElab+totalCheck)~/n/1000).toStringAsFixed(2)}ms');
  print('decls:  ${(prog.decls.length)}');

  // Church depth 500
  print('');
  final churchSrc = _churchChain(500);
  totalParse = 0; totalElab = 0; totalCheck = 0;

  for (var i = 0; i < 3; i++) {
    sw.reset(); sw.start();
    final prog = parseProgram(churchSrc).value as SProgram;
    sw.stop(); totalParse += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList();
    var elabUs = 0, checkUs = 0;
    for (final decl in prog.decls) {
      sw.reset(); sw.start();
      final produced = elabDecl(TopEnv(b, d), decl);
      sw.stop(); elabUs += sw.elapsedMicroseconds;

      sw.reset(); sw.start();
      final rd = [...d, ...produced.dataDecls];
      final finalized = checkDeclResult(TopEnv(b, rd), produced);
      sw.stop(); checkUs += sw.elapsedMicroseconds;
      b = [...b, ...finalized];
      d = rd;
    }
    totalElab += elabUs;
    totalCheck += checkUs;
  }

  print('=== church_depth_500 (average of $n runs) ===');
  print('parse:  ${(totalParse~/n/1000).toStringAsFixed(2)}ms');
  print('elab:   ${(totalElab~/n/1000).toStringAsFixed(2)}ms');
  print('check:  ${(totalCheck~/n/1000).toStringAsFixed(2)}ms');
  print('total:  ${((totalParse+totalElab+totalCheck)~/n/1000).toStringAsFixed(2)}ms');
  print('decls:  ${(prog.decls.length)}');
}

void _check(String src, List<TopBinding> bindings, List<DataDecl> dataDecls) {
  final prog = parseProgram(src).value as SProgram;
  var b = bindings.toList(), d = dataDecls.toList();
  for (final decl in prog.decls) {
    final produced = elabDecl(TopEnv(b, d), decl);
    final rd = [...d, ...produced.dataDecls];
    b = [...b, ...checkDeclResult(TopEnv(b, rd), produced)];
    d = rd;
  }
}

String _read(String path) => File(path).readAsStringSync();

String _churchChain(int depth) {
  final buf = StringBuffer();
  buf.writeln('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
  buf.writeln('val id : Nat -> Nat = (x: Nat) => x');
  buf.write('val chain : Nat = ');
  for (var i = 0; i < depth; i++) buf.write('id(');
  buf.write('zero');
  for (var i = 0; i < depth; i++) buf.write(')');
  return buf.toString();
}

import 'dart:io';
