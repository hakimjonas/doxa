/// Profiling: parse vs elab vs check breakdown, plus eval/conv stress.

import 'dart:developer';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart'
    show
        checkDeclResult,
        currentImportPath,
        elabDecl,
        importedPaths,
        DeclResult,
        TopEnv,
        TopBinding,
        DataDecl;
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart' show SProgram, SImportKind;
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:doxa/src/prelude.dart' show mergeNamespace;
import 'package:rumil/rumil.dart';
import 'dart:io';
import 'dart:math';

const _prelude = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}

data Acc[A: Type] : (A -> A -> Prop) -> A -> Prop {
  acc_intro : (R: A -> A -> Prop) -> (x: A) -> ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
''';

void main() {
  // Seed prelude
  var b = <TopBinding>[], d = <DataDecl>[], ns = <String, Set<String>>{};
  for (final decl in _parse(_prelude).decls) {
    final prod = elabDecl(TopEnv(b, d, const {}, ns), decl);
    final rd = [...d, ...prod.dataDecls];
    b = [...b, ...checkDeclResult(TopEnv(b, rd, const {}, ns), prod)];
    d = rd;
    ns = mergeNamespace(ns, prod.namespaceBindings);
  }

  profileStdlib(b, d, ns);
  profileChurch(b, d, ns, 500);
  profileEvalStress();
}

void profileStdlib(
  List<TopBinding> bindings,
  List<DataDecl> dataDecls,
  Map<String, Set<String>> namespaceBindings,
) {
  final src = File('lib/stdlib/proofs.doxa').readAsStringSync();
  final prog = _parse(src);

  currentImportPath = 'lib/stdlib/proofs.doxa';
  importedPaths.clear();
  final sw = Stopwatch();

  // Warmup
  _check(prog, bindings, dataDecls, namespaceBindings);

  // Timed — 5 runs
  var parseUs = 0, elabUs = 0, checkUs = 0;
  const n = 5;
  for (var r = 0; r < n; r++) {
    importedPaths.clear();
    // Re-parse every iteration (avoids caching)
    sw.reset();
    sw.start();
    final p = _parse(src);
    sw.stop();
    parseUs += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
    var elabAcc = 0, checkAcc = 0;
    for (final decl in p.decls) {
      sw.reset();
      sw.start();
      final prod = elabDecl(TopEnv(b, d, const {}, ns), decl);
      sw.stop();
      elabAcc += sw.elapsedMicroseconds;

      sw.reset();
      sw.start();
      final rd = [...d, ...prod.dataDecls];
      final checkBindings =
          decl.kind is SImportKind ? [...b, ...prod.bindings] : b;
      final fin = checkDeclResult(
        TopEnv(checkBindings, rd, const {}, ns),
        prod,
      );
      sw.stop();
      checkAcc += sw.elapsedMicroseconds;
      b = [...b, ...fin];
      d = rd;
      ns = mergeNamespace(ns, prod.namespaceBindings);
    }
    elabUs += elabAcc;
    checkUs += checkAcc;
  }

  print('stdlib/proofs (${prog.decls.length} decls, avg $n runs, Dart JIT):');
  print(
    '  parse: ${(parseUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * parseUs / (parseUs + elabUs + checkUs)).toStringAsFixed(0)}%)',
  );
  print(
    '  elab:  ${(elabUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * elabUs / (parseUs + elabUs + checkUs)).toStringAsFixed(0)}%)',
  );
  print(
    '  check: ${(checkUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * checkUs / (parseUs + elabUs + checkUs)).toStringAsFixed(0)}%)',
  );
  print('');
}

void profileChurch(
  List<TopBinding> bindings,
  List<DataDecl> dataDecls,
  Map<String, Set<String>> namespaceBindings,
  int depth,
) {
  final src = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
val id : Nat -> Nat = (x: Nat) => x
val chain : Nat = ${List.filled(depth, 'id(').join() + 'zero' + List.filled(depth, ')').join()}
''';

  final sw = Stopwatch();
  final prog = _parse(src);
  _check(prog, bindings, dataDecls, namespaceBindings);

  var parseUs = 0, elabUs = 0, checkUs = 0;
  const n = 3;
  for (var r = 0; r < n; r++) {
    sw.reset();
    sw.start();
    final p = _parse(src);
    sw.stop();
    parseUs += sw.elapsedMicroseconds;

    var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
    var elabAcc = 0, checkAcc = 0;
    for (final decl in p.decls) {
      sw.reset();
      sw.start();
      final prod = elabDecl(TopEnv(b, d, const {}, ns), decl);
      sw.stop();
      elabAcc += sw.elapsedMicroseconds;

      sw.reset();
      sw.start();
      final rd = [...d, ...prod.dataDecls];
      final fin = checkDeclResult(TopEnv(b, rd, const {}, ns), prod);
      sw.stop();
      checkAcc += sw.elapsedMicroseconds;
      b = [...b, ...fin];
      d = rd;
      ns = mergeNamespace(ns, prod.namespaceBindings);
    }
    elabUs += elabAcc;
    checkUs += checkAcc;
  }

  final total = parseUs + elabUs + checkUs;
  print('church_depth_$depth (avg $n runs, Dart JIT):');
  print(
    '  parse: ${(parseUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * parseUs / total).toStringAsFixed(0)}%)',
  );
  print(
    '  elab:  ${(elabUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * elabUs / total).toStringAsFixed(0)}%)',
  );
  print(
    '  check: ${(checkUs ~/ n / 1000).toStringAsFixed(2)}ms (${(100.0 * checkUs / total).toStringAsFixed(0)}%)',
  );
  print('');
}

void profileEvalStress() {
  // Build an eval chain: eval deep TApp of identity on TType(0)
  // to measure pure β-reduction without elaborator overhead.
  Term chain(int n) {
    Term t = const TType(LLevel(0));
    const id = TLam(TType(LLevel(0)), TBound(0));
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
      sw.reset();
      sw.start();
      eval(t, env);
      sw.stop();
      us += sw.elapsedMicroseconds;
    }
    print(
      'eval deep TApp chain depth=$depth (avg ${n} runs): ${(us ~/ n / 1000).toStringAsFixed(2)}ms',
    );
  }
  print('');

  // Conv stress: compare two deep Pi chains
  for (final depth in [100, 500, 1000, 5000]) {
    Value deepPi(int n) {
      Value v = VType(LLevel(0));
      for (var i = 0; i < n; i++) {
        final body = TType(LLevel(0));
        v = VPi(VType(LLevel(0)), Closure(ENil(), body));
      }
      return v;
    }

    final a = deepPi(depth);
    final b = deepPi(depth);
    final sw = Stopwatch();
    conv(0, a, b); // warmup
    var us = 0;
    for (var i = 0; i < n; i++) {
      sw.reset();
      sw.start();
      conv(0, a, b);
      sw.stop();
      us += sw.elapsedMicroseconds;
    }
    print(
      'conv deep Pi chain depth=$depth (avg ${n} runs): ${(us ~/ n / 1000).toStringAsFixed(2)}ms',
    );
  }
}

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  throw StateError('parse failed');
}

void _check(
  SProgram prog,
  List<TopBinding> bindings,
  List<DataDecl> dataDecls,
  Map<String, Set<String>> namespaceBindings,
) {
  var b = bindings.toList(), d = dataDecls.toList(), ns = namespaceBindings;
  for (final decl in prog.decls) {
    final env = TopEnv(b, d, const {}, ns);
    final prod = elabDecl(env, decl);
    final rd = [...d, ...prod.dataDecls];
    final checkBindings =
        decl.kind is SImportKind ? [...b, ...prod.bindings] : b;
    b = [
      ...b,
      ...checkDeclResult(TopEnv(checkBindings, rd, const {}, ns), prod),
    ];
    d = rd;
    ns = mergeNamespace(ns, prod.namespaceBindings);
  }
}
