/// Quick profiling: run stdlib proofs and church depth 500 with breakdown.

import 'dart:developer';
import 'dart:io';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart'
    show
        checkDeclResult,
        ImportState,
        elabDecl,
        mergeNamespace,
        TopEnv,
        TopBinding,
        DataDecl;
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart' show SProgram, SImportKind;
import 'package:rumil/rumil.dart';

const prelude = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}

data Acc[A: Type] : (A -> A -> Prop) -> A -> Prop {
  acc_intro : (R: A -> A -> Prop) -> (x: A) -> ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
''';

void main() {
  // Load prelude
  var bindings = <TopBinding>[];
  var dataDecls = <DataDecl>[];
  var namespaceBindings = <String, Set<String>>{};
  for (final decl in _parseProg(prelude).decls) {
    final p = elabDecl(
      TopEnv(bindings, dataDecls, const {}, namespaceBindings),
      decl,
    );
    final rd = [...dataDecls, ...p.dataDecls];
    bindings = [
      ...bindings,
      ...checkDeclResult(TopEnv(bindings, rd, const {}, namespaceBindings), p),
    ];
    dataDecls = rd;
    namespaceBindings = mergeNamespace(namespaceBindings, p.namespaceBindings);
  }

  // stdlib proofs
  final src = _read('lib/stdlib/proofs.doxa');
  final sw = Stopwatch();
  var totalParse = 0, totalElab = 0, totalCheck = 0, totalNf = 0;

  // Warmup
  final importState = ImportState();
  importState.currentImportPath = 'lib/stdlib/proofs.doxa';
  importState.importedPaths.clear();
  _check(src, bindings, dataDecls, namespaceBindings, importState);

  // Timed run
  SProgram stdlibProg = _parseProg(src);
  for (var i = 0; i < 3; i++) {
    importState.importedPaths.clear();
    sw.reset();
    sw.start();
    final prog = _parseProg(src);
    sw.stop();
    totalParse += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
    var elabUs = 0, checkUs = 0;

    for (final decl in prog.decls) {
      sw.reset();
      sw.start();
      final produced = elabDecl(TopEnv(b, d, const {}, ns, importState), decl);
      sw.stop();
      elabUs += sw.elapsedMicroseconds;

      sw.reset();
      sw.start();
      final rd = [...d, ...produced.dataDecls];
      final checkBindings =
          decl.kind is SImportKind ? [...b, ...produced.bindings] : b;
      final finalized = checkDeclResult(
        TopEnv(checkBindings, rd, const {}, ns, importState),
        produced,
      );
      sw.stop();
      checkUs += sw.elapsedMicroseconds;
      b = [...b, ...finalized];
      d = rd;
      ns = mergeNamespace(ns, produced.namespaceBindings);
    }
    totalElab += elabUs;
    totalCheck += checkUs;
  }

  // Average
  final n = 3;
  print('=== stdlib/proofs (average of $n runs) ===');
  print('parse:  ${(totalParse ~/ n / 1000).toStringAsFixed(2)}ms');
  print('elab:   ${(totalElab ~/ n / 1000).toStringAsFixed(2)}ms');
  print('check:  ${(totalCheck ~/ n / 1000).toStringAsFixed(2)}ms');
  print(
    'total:  ${((totalParse + totalElab + totalCheck) ~/ n / 1000).toStringAsFixed(2)}ms',
  );
  print('decls:  ${stdlibProg.decls.length}');

  // Church depth 500
  print('');
  final churchSrc = _churchChain(500);
  final churchProg = _parseProg(churchSrc);
  totalParse = 0;
  totalElab = 0;
  totalCheck = 0;

  for (var i = 0; i < 3; i++) {
    sw.reset();
    sw.start();
    final prog = _parseProg(churchSrc);
    sw.stop();
    totalParse += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
    var elabUs = 0, checkUs = 0;
    for (final decl in prog.decls) {
      sw.reset();
      sw.start();
      final produced = elabDecl(TopEnv(b, d, const {}, ns, importState), decl);
      sw.stop();
      elabUs += sw.elapsedMicroseconds;

      sw.reset();
      sw.start();
      final rd = [...d, ...produced.dataDecls];
      final finalized = checkDeclResult(
        TopEnv(b, rd, const {}, ns, importState),
        produced,
      );
      sw.stop();
      checkUs += sw.elapsedMicroseconds;
      b = [...b, ...finalized];
      d = rd;
      ns = mergeNamespace(ns, produced.namespaceBindings);
    }
    totalElab += elabUs;
    totalCheck += checkUs;
  }

  print('=== church_depth_500 (average of $n runs) ===');
  print('parse:  ${(totalParse ~/ n / 1000).toStringAsFixed(2)}ms');
  print('elab:   ${(totalElab ~/ n / 1000).toStringAsFixed(2)}ms');
  print('check:  ${(totalCheck ~/ n / 1000).toStringAsFixed(2)}ms');
  print(
    'total:  ${((totalParse + totalElab + totalCheck) ~/ n / 1000).toStringAsFixed(2)}ms',
  );
  print('decls:  ${churchProg.decls.length}');
}

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed');
}

void _check(
  String src,
  List<TopBinding> bindings,
  List<DataDecl> dataDecls,
  Map<String, Set<String>> namespaceBindings,
  ImportState importState,
) {
  final prog = _parseProg(src);
  var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
  for (final decl in prog.decls) {
    final env = TopEnv(b, d, const {}, ns, importState);
    final produced = elabDecl(env, decl);
    final rd = [...d, ...produced.dataDecls];
    final checkBindings =
        decl.kind is SImportKind ? [...b, ...produced.bindings] : b;
    b = [
      ...b,
      ...checkDeclResult(
        TopEnv(checkBindings, rd, const {}, ns, importState),
        produced,
      ),
    ];
    d = rd;
    ns = mergeNamespace(ns, produced.namespaceBindings);
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
