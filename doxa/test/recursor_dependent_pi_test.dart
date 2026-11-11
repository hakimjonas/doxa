/// Recursor-type synthesis for constructors whose recursive argument is a
/// dependent Pi chain.
///
/// These tests guard the de Bruijn rebasing in `_synthMethodType`: a domain
/// under the Pi chain may refer both to earlier Pi binders and to the
/// constructor's outer scope. The recursor type must be closed, so
/// `checkDeclResult` (which evaluates the synthesized type) and `infer` are
/// the signals.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate and declaration-check [src] the way the CLI does.
///
/// `elabProgram` elaborates only; recursor bindings are checked by
/// `checkDeclResult`, which is where an ill-formed synthesized type is
/// evaluated and crashes.
TopEnv _elabAndCheck(String src) {
  final program = _parse(src);
  var bindings = <TopBinding>[];
  var dataDecls = <DataDecl>[];
  var classRegistry = <String, ClassInfo>{};
  var namespaceBindings = <String, Set<String>>{};
  for (final decl in program.decls) {
    final produced = elabDecl(
      TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
      decl,
    );
    dataDecls = <DataDecl>[...dataDecls, ...produced.dataDecls];
    bindings = <TopBinding>[
      ...bindings,
      ...checkDeclResult(
        TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
        produced,
      ),
    ];
    classRegistry = <String, ClassInfo>{
      ...classRegistry,
      ...produced.classRegistry,
    };
    namespaceBindings = mergeNamespace(
      namespaceBindings,
      produced.namespaceBindings,
    );
  }
  return TopEnv(bindings, dataDecls, classRegistry, namespaceBindings);
}

TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

/// A locally declared prelude-style `Eq`; kernel tests do not load the
/// ambient prelude.
const _eq = '''
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}
''';

const _nat = '''
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
''';

const _acc = '''
data Acc[A: Type]: (A -> A -> Prop) -> A -> Prop {
  acc_intro: (R: A -> A -> Prop) -> (x: A) ->
    ((y: A) -> R y x -> Acc A R y) -> Acc A R x;
}
''';

void main() {
  group('recursor type synthesis for dependent Pi arguments', () {
    test('D6.rec has a closed type', () {
      // The second Pi domain `Eq A y y` is under the binder `y`. `A` is
      // an outer parameter there, not a Pi binder; the pre-fix rebasing
      // mapped it to a free TBound(3) and evaluation crashed.
      final env = _elabAndCheck('''
$_eq
data D6[A: Type]: Type {
  mk: ((y: A) -> Eq A y y -> D6 A) -> D6 A;
}
''');
      final rec = _binding(env, 'D6.rec');
      expect(() => infer(env.toCtx(), rec.type), returnsNormally);
    });

    test('D7.rec has a closed type with a three-binder dependent chain', () {
      // Domains reference both an earlier Pi binder and a parameter, and
      // the chain has more than two binders.
      final env = _elabAndCheck('''
$_eq
data D7[A: Type, B: Type]: Type {
  mk: ((x: A) -> (y: B) -> Eq A x x -> Eq B y y -> D7 A B) -> D7 A B;
}
''');
      final rec = _binding(env, 'D7.rec');
      expect(() => infer(env.toCtx(), rec.type), returnsNormally);
    });

    test('Acc.rec has a closed type', () {
      // `acc_intro`'s recursive argument is
      // `(y: A) -> R y x -> Acc A R y`: two Pi binders whose second
      // domain references both the first binder (`y`) and outer
      // constructor arguments (`R`, `x`). The sub-indices of the base
      // `Acc A R y` also mix a Pi binder with an outer reference.
      final env = _elabAndCheck('''
$_eq
$_nat
$_acc
val r = Acc.rec Nat
''');
      final rec = _binding(env, 'Acc.rec');
      expect(() => infer(env.toCtx(), rec.type), returnsNormally);
    });

    test('a fully applied Acc.rec with a Prop motive type-checks', () {
      // Exercises the synthesized IH shape: the IH must be
      // `(y: Nat) -> (r: R y x) -> P R y (f y r)`, function-shaped over
      // the same Pi chain as the recursive argument.
      final env = _elabAndCheck('''
$_eq
$_nat
$_acc
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_eq: (n: Nat) -> Acc Nat rel n -> Eq Nat n n =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rec
    Nat
    ((R: Nat -> Nat -> Prop) => (x: Nat) => (v: Acc Nat R x) => Eq Nat x x)
    rel
    n
    ((R: Nat -> Nat -> Prop) => (x: Nat) =>
      (f: (y: Nat) -> R y x -> Acc Nat R y) =>
      (ih: (y: Nat) -> (r: R y x) -> Eq Nat y y) =>
        refl x)
    h
''');
      expect(_binding(env, 'acc_eq').name, 'acc_eq');
      expect(
        () => infer(env.toCtx(), _binding(env, 'acc_eq').type),
        returnsNormally,
      );
    });
  });
}
