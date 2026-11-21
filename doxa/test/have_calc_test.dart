/// Tests for `have` steps and `calc` chains.
library;

import 'package:doxa/src/check.dart' show NotAType, TypeMismatch;
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

final PreludeData prelude = loadPrelude();

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate and declaration-check [src] the way the CLI does, starting
/// from the prelude, so the tactic-built terms are kernel-checked.
TopEnv _elabAndCheck(String src) {
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  final prog = _parse(src);
  for (final decl in prog.decls) {
    final produced = elabDecl(env, decl);
    final checked = checkDeclResult(
      TopEnv(
        env.bindings,
        [...env.dataDecls, ...produced.dataDecls],
        env.classRegistry,
        env.namespaceBindings,
      ),
      produced,
    );
    env = TopEnv(
      [...env.bindings, ...checked],
      [...env.dataDecls, ...produced.dataDecls],
      {...env.classRegistry, ...produced.classRegistry},
      mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
    );
  }
  return env;
}

/// The smallest data prelude the tactic tests need.
const _natBool = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
data Bool : Type {
  true_ : Bool;
  false_ : Bool;
}
''';

void main() {
  group('have', () {
    test('a fact is available to exact', () {
      final env = _elabAndCheck('''
$_natBool
theorem t : (n: Nat) -> Eq Nat n n = by {
  intro n;
  have h: Eq Nat n n = refl n;
  exact h
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('a fact without a proof is a subgoal closed first', () {
      final env = _elabAndCheck('''
$_natBool
theorem t : (n: Nat) -> Eq Nat n n = by {
  intro n;
  have h: Eq Nat n n;
  refl;
  exact h
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('the fact goal comes before the main goal', () {
      // One step closes the fact. If the main goal came first the block
      // would be complete; the remaining-subgoal failure pins the order.
      expect(
        () => _elabAndCheck('''
$_natBool
theorem t : (n: Nat) -> Eq Nat n n = by {
  intro n;
  have h: Eq Nat n n;
  refl
}
'''),
        throwsA(
          isA<TacticFailed>().having(
            (e) => e.message,
            'message',
            contains('1 subgoal(s) remain'),
          ),
        ),
      );
    });

    test('two facts chain through the earlier one', () {
      final env = _elabAndCheck('''
$_natBool
theorem t : (n: Nat) -> Eq Nat n n = by {
  intro n;
  have h1: Eq Nat n n = refl n;
  have h2: Eq Nat n n = h1;
  exact h2
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('a fact is available to rewrite', () {
      final env = _elabAndCheck('''
$_natBool
theorem t : (A: Type) -> (x: A) -> (y: A) -> Eq A x y -> Eq A y x = by {
  intro A;
  intro x;
  intro y;
  intro h;
  have h2: Eq A x y = h;
  rewrite h2;
  refl
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('a proof that does not have the declared type is rejected', () {
      expect(
        () => _elabAndCheck('''
$_natBool
theorem t : Eq Nat zero zero = by {
  have h: Eq Nat zero (succ zero) = refl zero;
  exact h
}
'''),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('a fact whose declared type is not a type is rejected', () {
      expect(
        () => _elabAndCheck('''
$_natBool
theorem t : Eq Nat zero zero = by {
  have h: zero = refl zero;
  exact h
}
'''),
        throwsA(isA<NotAType>()),
      );
    });

    test('a fact works on an apply argument goal', () {
      // The argument goal's meta is closed over the local context; the
      // fact's goal is a fresh open goal in the extended context, so the
      // closed-goal path needs nothing new.
      final env = _elabAndCheck('''
$_natBool
fun const(A: Type, x: A, y: A): A = x
theorem t : (A: Type) -> A -> A = by {
  intro A;
  intro a;
  apply const;
  have h: A = a;
  exact h;
  exact a
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('a fact name shadows an outer binder and the fact wins', () {
      // The fact's own type and proof still see the outer `n`; after the
      // fact is introduced, `n` resolves to the fact. If the outer binder
      // won, `exact n` would be a Nat and the block would fail.
      final env = _elabAndCheck('''
$_natBool
theorem t : (n: Nat) -> Eq Nat n n = by {
  intro n;
  have n: Eq Nat n n = refl n;
  exact n
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });
  });

  group('calc', () {
    test('a two-step chain composes the two proofs', () {
      final env = _elabAndCheck('''
$_natBool
fun chain{A: Type, x: A, y: A, z: A}(p: Eq A x y, q: Eq A y z): Eq A x z =
  calc(x = y := p; y = z := q)
''');
      expect(env.bindings.where((b) => b.name == 'chain'), hasLength(1));
    });

    test('a one-step chain is its proof', () {
      final env = _elabAndCheck('''
$_natBool
fun one{A: Type, x: A, y: A}(p: Eq A x y): Eq A x y = calc(x = y := p)
''');
      expect(env.bindings.where((b) => b.name == 'one'), hasLength(1));
    });

    test('a chain works inside exact', () {
      final env = _elabAndCheck('''
$_natBool
theorem t : (A: Type) -> (x: A) -> (y: A) -> (z: A) ->
    Eq A x y -> Eq A y z -> Eq A x z = by {
  intro A;
  intro x;
  intro y;
  intro z;
  intro p;
  intro q;
  exact calc(x = y := p; y = z := q)
}
''');
      expect(env.bindings.where((b) => b.name == 't'), hasLength(1));
    });

    test('a chain works as an application argument', () {
      final env = _elabAndCheck('''
$_natBool
fun idEq{A: Type, x: A, y: A}(p: Eq A x y): Eq A x y = p
fun arg{A: Type, x: A, y: A}(p: Eq A x y): Eq A x y =
  idEq calc(x = y := p)
''');
      expect(env.bindings.where((b) => b.name == 'arg'), hasLength(1));
    });

    test('a wrong endpoint is rejected with a type mismatch', () {
      expect(
        () => _elabAndCheck('''
$_natBool
val bad : Nat = calc(zero = true_ := refl zero)
'''),
        throwsA(
          isA<TypeMismatch>().having(
            (e) => e.span?.start,
            'span start',
            isNotNull,
          ),
        ),
      );
    });

    test('a step proof for the wrong equality is rejected', () {
      expect(
        () => _elabAndCheck('''
$_natBool
val bad : Eq Nat zero zero = calc(zero = zero := refl (succ zero))
'''),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('a chain over a Prop carrier is rejected as not a type', () {
      expect(
        () => _elabAndCheck('''
$_natBool
val bad : Eq Nat zero zero = calc(refl zero = refl zero := refl (refl zero))
'''),
        throwsA(isA<NotAType>()),
      );
    });

    test('steps that do not meet are rejected', () {
      expect(
        () => _elabAndCheck('''
$_natBool
fun broken{A: Type, x: A, y: A, z: A}(p: Eq A x y, q: Eq A z z): Eq A x y =
  calc(x = y := p; z = z := q)
'''),
        throwsA(isA<TypeMismatch>()),
      );
    });
  });
}
