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

  group('iota reduction for function-typed recursive arguments', () {
    // Each `refl zero` below type-checks only if the eliminator
    // actually reduces to the method result: the `refl` proof forces
    // conversion of the recursor application with `zero`.

    test('D4.rec reduces a non-dependent function-typed argument', () {
      final env = _elabAndCheck('''
$_eq
$_nat
data D4[A: Type]: Type {
  mk4: (x: A) -> ((y: A) -> D4 A) -> D4 A;
}
val d4_iota: (f: (y: Nat) -> D4 Nat) ->
  Eq Nat (D4.rec Nat ((v: D4 Nat) => Nat)
    ((x: Nat) => (f: (y: Nat) -> D4 Nat) =>
      (ih: (y: Nat) -> Nat) => zero)
    (mk4 zero f)) zero =
  (f: (y: Nat) -> D4 Nat) => refl zero
''');
      expect(_binding(env, 'd4_iota').name, 'd4_iota');
    });

    test('D5.rec reduces a dependent function-typed argument', () {
      final env = _elabAndCheck('''
$_eq
$_nat
data D5[A: Type]: Type {
  mk5: (x: A) -> ((y: A) -> Eq A y x -> D5 A) -> D5 A;
}
val d5_iota: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
  Eq Nat (D5.rec Nat ((v: D5 Nat) => Nat)
    ((x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
      (ih: (y: Nat) -> (e: Eq Nat y x) -> Nat) => zero)
    (mk5 x f)) zero =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) => refl zero
''');
      expect(_binding(env, 'd5_iota').name, 'd5_iota');
    });

    test('Acc.rect reduces', () {
      final env = _elabAndCheck('''
$_eq
$_nat
$_acc
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_rect_true: (n: Nat) -> Acc Nat rel n -> Nat =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rect Nat
    ((R: Nat -> Nat -> Prop) => (x: Nat) => (v: Acc Nat R x) => Nat)
    rel n
    ((R: Nat -> Nat -> Prop) => (x: Nat) =>
      (f: (y: Nat) -> R y x -> Acc Nat R y) =>
      (ih: (y: Nat) -> (r: R y x) -> Nat) => zero)
    h
val acc_rect_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  Eq Nat (acc_rect_true n (acc_intro rel n f)) zero =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => refl zero
''');
      expect(_binding(env, 'acc_rect_iota').name, 'acc_rect_iota');
    });

    test('the Prop-motive Acc.rec observer reduces', () {
      final env = _elabAndCheck('''
$_eq
$_nat
$_acc
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_true: (n: Nat) -> Acc Nat rel n -> Eq Nat n n =
  (n: Nat) => (h: Acc Nat rel n) => Acc.rec Nat
    ((R: Nat -> Nat -> Prop) => (x: Nat) => (v: Acc Nat R x) => Eq Nat x x)
    rel n
    ((R: Nat -> Nat -> Prop) => (x: Nat) =>
      (f: (y: Nat) -> R y x -> Acc Nat R y) =>
      (ih: (y: Nat) -> (r: R y x) -> Eq Nat y y) => refl x)
    h
val observe:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) -> Nat =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => Eq.rect Nat
    ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => Nat)
    n n ((z: Nat) => zero)
    (acc_true n (acc_intro rel n f))
val observe_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  Eq Nat (observe n f) zero =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => refl zero
''');
      expect(_binding(env, 'observe_iota').name, 'observe_iota');
    });

    test('D4.rec applies the function-typed IH', () {
      // The step applies the IH to `x`, so this only type-checks if the
      // IH is the recursive call `D4.rec ... (f x)`, not an arbitrary
      // function of the right type.
      final env = _elabAndCheck('''
$_eq
$_nat
data D4[A: Type]: Type {
  mk4: (x: A) -> ((y: A) -> D4 A) -> D4 A;
}
val step: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> ((y: Nat) -> Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) => (ih: (y: Nat) -> Nat) => succ (ih x)
val d4_use: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) =>
    D4.rec Nat ((_: D4 Nat) => Nat) step (mk4 x f)
val d4_expected: (x: Nat) -> (f: (y: Nat) -> D4 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) =>
    succ (D4.rec Nat ((_: D4 Nat) => Nat) step (f x))
val d4_use_iota: (x: Nat) -> (f: (y: Nat) -> D4 Nat) ->
  Eq Nat (d4_use x f) (d4_expected x f) =
  (x: Nat) => (f: (y: Nat) -> D4 Nat) => refl (d4_expected x f)
''');
      expect(_binding(env, 'd4_use_iota').name, 'd4_use_iota');
    });

    test('D5.rec applies the dependent function-typed IH', () {
      // The IH is applied at `x` with the proof `refl x`, so both the
      // dependent domain and the recursive-call body must line up.
      final env = _elabAndCheck('''
$_eq
$_nat
data D5[A: Type]: Type {
  mk5: (x: A) -> ((y: A) -> Eq A y x -> D5 A) -> D5 A;
}
val step5: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
    ((y: Nat) -> (e: Eq Nat y x) -> Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
  (ih: (y: Nat) -> (e: Eq Nat y x) -> Nat) => succ (ih x (refl x))
val d5_use: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    D5.rec Nat ((_: D5 Nat) => Nat) step5 (mk5 x f)
val d5_expected: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    succ (D5.rec Nat ((_: D5 Nat) => Nat) step5 (f x (refl x)))
val d5_use_iota: (x: Nat) -> (f: (y: Nat) -> Eq Nat y x -> D5 Nat) ->
  Eq Nat (d5_use x f) (d5_expected x f) =
  (x: Nat) => (f: (y: Nat) -> Eq Nat y x -> D5 Nat) =>
    refl (d5_expected x f)
''');
      expect(_binding(env, 'd5_use_iota').name, 'd5_use_iota');
    });

    test('Acc.rect applies the function-typed IH', () {
      // The step applies the IH at the constructor's own index and
      // proof, so the recursor result must be the recursive call on
      // `f n r`. Acc is Prop-sorted, so the Type-valued motive needs
      // the large-elim variant `Acc.rect`.
      final env = _elabAndCheck('''
$_eq
$_nat
$_acc
fun rel(a: Nat, b: Nat): Prop = Eq Nat a b
val acc_motive:
  (R: Nat -> Nat -> Prop) -> (x: Nat) -> (v: Acc Nat R x) -> Type =
  (R: Nat -> Nat -> Prop) => (x: Nat) => (v: Acc Nat R x) =>
    (r: R x x) -> Nat
val acc_step:
  (R: Nat -> Nat -> Prop) -> (x: Nat) ->
  (f: (y: Nat) -> R y x -> Acc Nat R y) ->
  (ih: (y: Nat) -> (r: R y x) -> (r2: R y y) -> Nat) ->
  (r: R x x) -> Nat =
  (R: Nat -> Nat -> Prop) => (x: Nat) =>
  (f: (y: Nat) -> R y x -> Acc Nat R y) =>
  (ih: (y: Nat) -> (r: R y x) -> (r2: R y y) -> Nat) =>
  (r: R x x) => ih x r r
val acc_ih: (n: Nat) -> (h: Acc Nat rel n) -> (r: rel n n) -> Nat =
  (n: Nat) => (h: Acc Nat rel n) =>
    Acc.rect Nat acc_motive rel n acc_step h
val acc_expected:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  (r: rel n n) -> Nat =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => (r: rel n n) =>
    Acc.rect Nat acc_motive rel n acc_step (f n r) r
val acc_ih_iota:
  (n: Nat) -> (f: (y: Nat) -> rel y n -> Acc Nat rel y) ->
  (r: rel n n) ->
  Eq Nat (acc_ih n (acc_intro rel n f) r) (acc_expected n f r) =
  (n: Nat) => (f: (y: Nat) -> rel y n -> Acc Nat rel y) => (r: rel n n) =>
    refl (acc_expected n f r)
''');
      expect(_binding(env, 'acc_ih_iota').name, 'acc_ih_iota');
    });

    test('Tree.rec selects the nodeT method and preserves the spine', () {
      // Two constructors: the recursor spine has one method per ctor,
      // and nodeT is method index 1. The function-typed IH must be the
      // recursive call on `f x`, so the head spine (params, motive,
      // both methods) must survive the iota step intact.
      final env = _elabAndCheck('''
$_eq
$_nat
data Tree[A: Type]: Type {
  leafT: Tree A;
  nodeT: (x: A) -> ((y: A) -> Tree A) -> Tree A;
}
val tree_count: (t: Tree Nat) -> Nat =
  (t: Tree Nat) => Tree.rec Nat ((_: Tree Nat) => Nat)
    zero
    ((x: Nat) => (f: (y: Nat) -> Tree Nat) =>
      (ih: (y: Nat) -> Nat) => succ (ih x))
    t
val tree_use: (x: Nat) -> (f: (y: Nat) -> Tree Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => tree_count (nodeT x f)
val tree_expected: (x: Nat) -> (f: (y: Nat) -> Tree Nat) -> Nat =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => succ (tree_count (f x))
val tree_iota: (x: Nat) -> (f: (y: Nat) -> Tree Nat) ->
  Eq Nat (tree_use x f) (tree_expected x f) =
  (x: Nat) => (f: (y: Nat) -> Tree Nat) => refl (tree_expected x f)
''');
      expect(_binding(env, 'tree_iota').name, 'tree_iota');
    });
  });
}
