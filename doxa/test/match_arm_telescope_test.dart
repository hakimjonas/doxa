/// Match arm telescopes must be built in the data type's parameter order:
/// parameters are outermost-first, and `Env.extend` prepends, so the arm
/// environment extends `paramsV[0]` first.
library;

import 'package:doxa/src/check.dart' show IndexedMatchNotExhaustive;
import 'package:doxa/src/elab.dart';
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

void main() {
  group('match arm parameter telescopes', () {
    test('two-parameter D gives the arm binder the second parameter', () {
      final env = _elabAndCheck('''
data B1: Type {
  b1: B1;
}
data B2: Type {
  b2: B2;
}
data D[A: Type, B: Type]: Type {
  mkD: (x: B) -> D A B;
}
fun f(d: D B1 B2): B2 = match d {
  case mkD x => x
}
val t: B2 = f (mkD b2)
''');
      expect(_binding(env, 'f').name, 'f');
      expect(_binding(env, 't').name, 't');
    });

    test('three-parameter D3 gives the arm binder the third parameter', () {
      final env = _elabAndCheck('''
data A1: Type {
  a1: A1;
}
data B1: Type {
  b1: B1;
}
data C1: Type {
  c1: C1;
}
data D3[A: Type, B: Type, C: Type]: Type {
  mk3: (x: C) -> D3 A B C;
}
fun f3(d: D3 A1 B1 C1): C1 = match d {
  case mk3 x => x
}
''');
      expect(_binding(env, 'f3').name, 'f3');
    });

    test('reachability gives the missing ctor its result index', () {
      // mkB's result index is the second parameter `m`, which is
      // `succ zero` in the scrutinee type. If params are reversed the
      // kernel reads `zero` and wrongly declares mkB unreachable.
      expect(
        () => _elabAndCheck('''
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data D[n: Nat, m: Nat]: Nat -> Type {
  mkA: D n m n;
  mkB: D n m m;
}
fun f(d: D zero (succ zero) (succ zero)): Nat = match d {
  case mkA => zero
}
'''),
        throwsA(
          isA<IndexedMatchNotExhaustive>().having(
            (e) => e.missingReachableCtors,
            'missingReachableCtors',
            ['mkB'],
          ),
        ),
      );
    });

    test('parameterized AccP, nat_wfP, and strong_ind_implP check', () {
      final env = _elabAndCheck('''
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data False: Prop {
}
data Lt: Nat -> Nat -> Prop {
  lt_succ: (n: Nat) -> Lt n (succ n);
  lt_trans: (n: Nat) -> (m: Nat) -> (k: Nat) ->
    Lt n m -> Lt m k -> Lt n k;
}
fun isZero(n: Nat): Prop = match n {
  case zero => Eq Nat zero zero
  case succ _ => False
}
val succ_ne_zero: (n: Nat) -> Eq Nat (succ n) zero -> False =
  (n: Nat) => (p: Eq Nat (succ n) zero) => Eq.rec
    Nat
    ((a: Nat) => (b: Nat) => (_: Eq Nat a b) => isZero b -> isZero a)
    (succ n)
    zero
    ((z: Nat) => (h: isZero z) => h)
    p
    (refl zero)
data AccP[A: Type, R: A -> A -> Prop]: A -> Prop {
  acc_introP: (x: A) ->
    ((y: A) -> R y x -> AccP A R y) -> AccP A R x;
}
fun ltP(a: Nat, b: Nat): Prop = Lt a b
fun nat_wfP(n: Nat): AccP Nat ltP n = match n {
  case zero => acc_introP zero
    ((y: Nat) => (h: Lt y zero) => False.rec
      ((_: False) => AccP Nat ltP y)
      (Lt.rec
        ((a: Nat) => (b: Nat) => (_: Lt a b) => Eq Nat b zero -> False)
        y
        zero
        ((n_: Nat) => (eq: Eq Nat (succ n_) zero) => succ_ne_zero n_ eq)
        ((n_: Nat) => (m: Nat) => (k: Nat) => (_: Lt n_ m) => (_: Lt m k) =>
          (_: Eq Nat m zero -> False) => (ih2: Eq Nat k zero -> False) =>
          (eq: Eq Nat k zero) => ih2 eq)
        h
        (refl zero)))
  case succ k => acc_introP (succ k)
    ((y: Nat) => (h: Lt y (succ k)) => nat_wfP_help k y h)
} and nat_wfP_help(k: Nat, y: Nat, h: Lt y (succ k)):
    AccP Nat ltP y {struct h} = match h {
  case lt_succ y_ => nat_wfP y_
  case lt_trans y_ m _ p1 p2 => match nat_wfP_help k m p2 {
    case acc_introP _ f => f y_ p1
  }
}
fun strong_ind_implP(
  n: Nat,
  P: Nat -> Prop,
  step: (n: Nat) -> ((k: Nat) -> Lt k n -> P k) -> P n
): P n =
  AccP.rec Nat ltP
    ((m: Nat) => (v: AccP Nat ltP m) => P m)
    n
    ((x: Nat) =>
      (f: (y: Nat) -> ltP y x -> AccP Nat ltP y) =>
      (ih: (y: Nat) -> (h: ltP y x) -> P y) =>
      step x ih)
    (nat_wfP n)
''');
      expect(_binding(env, 'nat_wfP').name, 'nat_wfP');
      expect(_binding(env, 'strong_ind_implP').name, 'strong_ind_implP');
    });
  });
}
