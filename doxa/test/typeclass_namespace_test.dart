/// Class-qualified projections: `Class.method` identities, bare-name
/// resolution through local dictionaries and the class registry, the
/// ambiguity diagnostic, and law fields that read the current class and its
/// parents.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse a program, asserting success.
SProgram pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

const _prelude = '''
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}

data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
''';

/// Evaluate a named top-level binding in [env].
Value _evalBinding(TopEnv env, String name) {
  final binding = env.bindings.firstWhere((b) => b.name == name);
  return eval(binding.term, env.toCtx().env);
}

String _ctorName(Value value) {
  expect(value, isA<VConstr>());
  return (value as VConstr).ctorName;
}

/// The number of `succ` wrappers on a `Nat` value.
int _natDepth(Value value) {
  var current = value;
  var depth = 0;
  while (current is VConstr && current.ctorName == 'succ') {
    current = current.args.last;
    depth += 1;
  }
  return depth;
}

/// Two classes with the same method name, plus their Nat instances.
const _twoTags = '''
typeclass Left[A: Type] {
  fun tag(x: A): A;
}
typeclass Right[A: Type] {
  fun tag(x: A): A;
}
impl Left[Nat] {
  fun tag(x: Nat): Nat = zero;
}
impl Right[Nat] {
  fun tag(x: Nat): Nat = succ x;
}
''';

void main() {
  group('class-qualified projections', () {
    test('two classes declare the same method and keep both projections', () {
      final env = checkProgram(pp('$_prelude\n$_twoTags'));

      expect(env.bindings.where((b) => b.name == 'Left.tag'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'Right.tag'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'tag'), isEmpty);
    });

    test('Class.method resolves a projection in a term and a type', () {
      final env = checkProgram(
        pp('''
$_prelude
$_twoTags
val qualifiedLeft: Nat = Left.tag (succ zero)
val qualifiedRight: Nat = Right.tag (succ zero)
val leftEq: Eq Nat (Left.tag (succ zero)) zero = refl zero
val rightEq: Eq Nat (Right.tag (succ zero)) (succ (succ zero)) =
  refl (succ (succ zero))
'''),
      );

      expect(_ctorName(_evalBinding(env, 'qualifiedLeft')), 'zero');
      expect(_ctorName(_evalBinding(env, 'qualifiedRight')), 'succ');
      expect(_ctorName(_evalBinding(env, 'leftEq')), 'refl');
      expect(_ctorName(_evalBinding(env, 'rightEq')), 'refl');
    });
  });

  group('bare-name resolution', () {
    test('a constrained parameter selects its class projection', () {
      final env = checkProgram(
        pp('''
$_prelude
$_twoTags
fun underLeft[A: Left](x: A): A = tag x
fun underRight[A: Right](x: A): A = tag x
val leftResult: Nat = underLeft Nat (succ zero)
val rightResult: Nat = underRight Nat (succ zero)
'''),
      );

      // The same bare `tag` reaches different projections.
      expect(_ctorName(_evalBinding(env, 'leftResult')), 'zero');
      expect(_ctorName(_evalBinding(env, 'rightResult')), 'succ');
    });

    test('a local dictionary selects its class projection', () {
      // A block `val` dictionary disambiguates the bare name, even
      // though both classes declare `tag`. SPEC's local dictionary is an
      // ordinary `val` binding of the dictionary type.
      final env = checkProgram(
        pp('''
$_prelude
$_twoTags
fun withLeft(x: Nat): Nat = {
  val d : Left Nat = mkLeft ((y: Nat) => zero);
  tag x
}
fun withRight(x: Nat): Nat = {
  val d : Right Nat = mkRight ((y: Nat) => succ y);
  tag x
}
val localLeft: Nat = withLeft (succ zero)
val localRight: Nat = withRight (succ zero)
'''),
      );

      expect(_ctorName(_evalBinding(env, 'localLeft')), 'zero');
      expect(_ctorName(_evalBinding(env, 'localRight')), 'succ');
    });

    test('a unique declaring class resolves without a local dictionary', () {
      final env = checkProgram(
        pp('''
$_prelude
typeclass Only[A: Type] {
  fun only(x: A): A;
}
impl Only[Nat] {
  fun only(x: Nat): Nat = succ x;
}
val resolved: Nat = only zero
'''),
      );

      expect(_ctorName(_evalBinding(env, 'resolved')), 'succ');
    });

    test('an ambiguous bare name names the candidate classes', () {
      expect(
        () => checkProgram(
          pp('''
$_prelude
$_twoTags
val bad: Nat = tag (succ zero)
'''),
        ),
        throwsA(
          isA<AmbiguousClassMethod>()
              .having((e) => e.methodName, 'methodName', 'tag')
              .having(
                (e) => e.candidates,
                'candidates',
                containsAll(<String>['Left.tag', 'Right.tag']),
              ),
        ),
      );
    });
  });

  group('superclass chain', () {
    const classes = '''
typeclass Base[A: Type] {
  fun probe(x: A): A;
}
typeclass Other[A: Type] {
  fun probe(x: A): A;
}
typeclass Sub[A: Type]: Base A {
  fun extra(): A;
}
impl Base[Nat] {
  fun probe(x: Nat): Nat = zero;
}
impl Other[Nat] {
  fun probe(x: Nat): Nat = succ x;
}
impl Sub[Nat] {
  fun extra(): Nat = succ zero;
}
''';

    test('a subclass dictionary reaches a parent method', () {
      final env = checkProgram(
        pp('''
$_prelude
$classes
fun throughSub[A: Sub](x: A): A = probe x
fun throughOther[A: Other](x: A): A = probe x
val subResult: Nat = throughSub Nat (succ zero)
val otherResult: Nat = throughOther Nat (succ zero)
'''),
      );

      expect(_ctorName(_evalBinding(env, 'subResult')), 'zero');
      expect(_ctorName(_evalBinding(env, 'otherResult')), 'succ');
    });

    test('a subclass-qualified name resolves to the parent projection', () {
      final env = checkProgram(
        pp('''
$_prelude
$classes
val viaSub: Nat = Sub.probe (succ zero)
val viaBase: Nat = Base.probe (succ zero)
val viaSubEq: Eq Nat (Sub.probe (succ zero)) zero = refl zero
'''),
      );

      expect(_ctorName(_evalBinding(env, 'viaSub')), 'zero');
      expect(_ctorName(_evalBinding(env, 'viaBase')), 'zero');
      expect(_ctorName(_evalBinding(env, 'viaSubEq')), 'refl');
    });
  });

  group('multiply under Monoid and Ring', () {
    test('the constraint selects a different multiply projection', () {
      // `Monoid.multiply` returns its left argument and `Ring.multiply` its right
      // argument, so the reduced values show which projection ran.
      final env = checkProgram(
        pp('''
$_prelude
typeclass AddGroup[A: Type] {
  fun add(x: A, y: A): A;
}
typeclass Monoid[A: Type] {
  fun multiply(x: A, y: A): A;
}
typeclass Ring[A: Type]: AddGroup A {
  fun multiply(x: A, y: A): A;
}
impl Monoid[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = x;
}
impl AddGroup[Nat] {
  fun add(x: Nat, y: Nat): Nat = plus x y;
}
impl Ring[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = y;
}
fun monoidMul[A: Monoid](x: A, y: A): A = multiply x y
fun ringMul[A: Ring](x: A, y: A): A = multiply x y
val left: Nat = monoidMul Nat zero (succ zero)
val right: Nat = ringMul Nat zero (succ zero)
'''),
      );

      expect(_ctorName(_evalBinding(env, 'left')), 'zero');
      expect(_ctorName(_evalBinding(env, 'right')), 'succ');
    });
  });

  group('class law fields', () {
    const classes = '''
typeclass MulOnly[A: Type] {
  fun multiply(x: A, y: A): A;
}
typeclass Base[A: Type] {
  fun add(x: A, y: A): A;
}
typeclass Ringy[A: Type]: Base A {
  fun multiply(x: A, y: A): A;
  fun ownLaw(x: A): Eq A (multiply x x) (multiply x x);
  fun parentLaw(x: A): Eq A (add x x) (add x x);
}
''';

    test('a law reads its own method, then a parent method', () {
      // `multiply` is declared by both `MulOnly` and `Ringy`, so the bare name
      // is ambiguous outside a class. Inside `Ringy`, the current class
      // wins for `multiply`; `add` resolves through the parent `Base`.
      final env = checkProgram(pp('$_prelude\n$classes'));

      expect(env.bindings.where((b) => b.name == 'Ringy.ownLaw'), hasLength(1));
      expect(
        env.bindings.where((b) => b.name == 'Ringy.parentLaw'),
        hasLength(1),
      );
    });

    test('the law types instantiate over Nat', () {
      final env = checkProgram(
        pp('''
$_prelude
$classes
impl MulOnly[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = succ x;
}
impl Base[Nat] {
  fun add(x: Nat, y: Nat): Nat = plus x y;
}
impl Ringy[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = plus x y;
  fun ownLaw(x: Nat): Eq Nat (plus x x) (plus x x) = refl (plus x x);
  fun parentLaw(x: Nat): Eq Nat (plus x x) (plus x x) = refl (plus x x);
}
val own : Eq Nat zero zero = Ringy.ownLaw zero
val parent : Eq Nat zero zero = Ringy.parentLaw zero
'''),
      );

      expect(_ctorName(_evalBinding(env, 'own')), 'refl');
      expect(_ctorName(_evalBinding(env, 'parent')), 'refl');
    });
  });

  group('top-level names and class methods', () {
    test('a unique class does not override a top-level function', () {
      // `only` names both the class method and a top-level function.
      // SPEC "Projection names" puts a local dictionary or the current
      // class first, then the top-level binding, then a unique class.
      final env = checkProgram(
        pp('''
$_prelude
typeclass Only[A: Type] {
  fun only(x: A): A;
}
impl Only[Nat] {
  fun only(x: Nat): Nat = succ x;
}
fun only(x: Nat): Nat = zero
fun underOnly[A: Only](x: A): A = only x
val top: Nat = only (succ zero)
val viaClass: Nat = Only.only (succ zero)
val constrained: Nat = underOnly Nat (succ zero)
'''),
      );

      expect(_natDepth(_evalBinding(env, 'top')), 0);
      expect(_natDepth(_evalBinding(env, 'viaClass')), 2);
      expect(_natDepth(_evalBinding(env, 'constrained')), 2);
    });

    test('a local dictionary selects the class method over the top level', () {
      final env = checkProgram(
        pp('''
$_prelude
typeclass Only[A: Type] {
  fun only(x: A): A;
}
impl Only[Nat] {
  fun only(x: Nat): Nat = succ x;
}
fun only(x: Nat): Nat = zero
fun underLocal(x: Nat): Nat = {
  val d : Only Nat = mkOnly ((y: Nat) => succ y);
  only x
}
val local: Nat = underLocal (succ zero)
'''),
      );

      expect(_natDepth(_evalBinding(env, 'local')), 2);
    });

    test(
      'a law body reads the current class when a top level shares the name',
      () {
        // The law is stated over `A`. If the body read the top-level `mark`,
        // the `mark x y` application would not type-check at `A`.
        final env = checkProgram(
          pp('''
$_prelude
typeclass Marked[A: Type] {
  fun mark(x: A, y: A): A;
  fun markLaw(x: A, y: A): Eq A (mark x y) (mark x y);
}
fun mark(x: Nat, y: Nat): Nat = y
'''),
        );

        expect(
          env.bindings.where((b) => b.name == 'Marked.markLaw'),
          hasLength(1),
        );
      },
    );

    test('the Nat multiply and the class multiply keep their own uses', () {
      // The top-level `multiply` returns `zero`; the class method returns
      // `plus x y`. A direct call, `square` under the constraint, and the
      // qualified projection therefore land on different definitions.
      final env = checkProgram(
        pp('''
$_prelude
typeclass Mult[A: Type] {
  fun multiply(x: A, y: A): A;
  fun multiplyLaw(x: A, y: A): Eq A (multiply x y) (multiply x y);
}
fun multiply(m: Nat, n: Nat): Nat = zero
impl Mult[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = plus x y;
  fun multiplyLaw(x: Nat, y: Nat): Eq Nat (plus x y) (plus x y) = refl (plus x y);
}
fun square[A: Mult](x: A): A = multiply x x
fun starSquare[A: Mult](x: A): A = x * x
val topLevel : Eq Nat (multiply (succ zero) (succ zero)) zero = refl zero
val classUse : Eq Nat (square Nat (succ zero)) (succ (succ zero)) =
  refl (succ (succ zero))
val starUse : Eq Nat (starSquare Nat (succ zero)) (succ (succ zero)) =
  refl (succ (succ zero))
val qualified : Eq Nat (Mult.multiply (succ zero) (succ zero)) (succ (succ zero)) =
  refl (succ (succ zero))
'''),
      );

      expect(_ctorName(_evalBinding(env, 'topLevel')), 'refl');
      expect(_ctorName(_evalBinding(env, 'classUse')), 'refl');
      expect(_ctorName(_evalBinding(env, 'starUse')), 'refl');
      expect(_ctorName(_evalBinding(env, 'qualified')), 'refl');
    });
  });

  group('commutative dictionaries', () {
    const classes = '''
typeclass AddMonoid[A: Type] {
  fun add(x: A, y: A): A;
}
typeclass AddGroup[A: Type]: AddMonoid A {
  fun negate(x: A): A;
}
typeclass AddCommMonoid[A: Type]: AddMonoid A {
  fun addComm(x: A, y: A): Eq A (add x y) (add y x);
}
typeclass AddCommGroup[A: Type]: AddGroup A {
  fun addComm(x: A, y: A): Eq A (add x y) (add y x);
}
typeclass Ring[A: Type]: AddGroup A {
  fun multiply(x: A, y: A): A;
}
typeclass CommRing[A: Type]: Ring A {
  fun addComm(x: A, y: A): Eq A (add x y) (add y x);
  fun multiplyComm(x: A, y: A): Eq A (x * y) (y * x);
}
''';

    test('a local dictionary selects its class addComm', () {
      // Each block has one local dictionary, and only that class has an
      // instance. A bare `addComm` that resolved to another declaring class
      // would therefore fail its implicit dictionary, so the successful
      // check pins the local dictionary's class.
      final monoid = checkProgram(
        pp('''
$_prelude
$classes
impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = zero;
}
impl AddCommMonoid[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
fun viaMonoid(x: Nat): Eq Nat zero zero = {
  val d : AddCommMonoid Nat =
    mkAddCommMonoid
      (mkAddMonoid ((y: Nat) => (z: Nat) => zero))
      ((y: Nat) => (z: Nat) => refl zero);
  addComm x x
}
val localMonoid : Eq Nat zero zero = viaMonoid zero
'''),
      );
      expect(_ctorName(_evalBinding(monoid, 'localMonoid')), 'refl');

      final group = checkProgram(
        pp('''
$_prelude
$classes
impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = zero;
}
impl AddGroup[Nat] {
  fun negate(x: Nat): Nat = zero;
}
impl AddCommGroup[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
fun viaGroup(x: Nat): Eq Nat zero zero = {
  val d : AddCommGroup Nat =
    mkAddCommGroup
      (mkAddGroup (mkAddMonoid ((y: Nat) => (z: Nat) => zero)) ((y: Nat) => y))
      ((y: Nat) => (z: Nat) => refl zero);
  addComm x x
}
val localGroup : Eq Nat zero zero = viaGroup zero
'''),
      );
      expect(_ctorName(_evalBinding(group, 'localGroup')), 'refl');

      final ring = checkProgram(
        pp('''
$_prelude
$classes
impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = zero;
}
impl AddGroup[Nat] {
  fun negate(x: Nat): Nat = zero;
}
impl Ring[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = zero;
}
impl CommRing[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
  fun multiplyComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
fun viaRing(x: Nat): Eq Nat zero zero = {
  val d : CommRing Nat =
    mkCommRing
      (mkRing
        (mkAddGroup (mkAddMonoid ((y: Nat) => (z: Nat) => zero)) ((y: Nat) => y))
        ((y: Nat) => (z: Nat) => zero))
      ((y: Nat) => (z: Nat) => refl zero)
      ((y: Nat) => (z: Nat) => refl zero);
  addComm x x
}
fun multiplyViaRing(x: Nat): Eq Nat zero zero = {
  val d : CommRing Nat =
    mkCommRing
      (mkRing
        (mkAddGroup (mkAddMonoid ((y: Nat) => (z: Nat) => zero)) ((y: Nat) => y))
        ((y: Nat) => (z: Nat) => zero))
      ((y: Nat) => (z: Nat) => refl zero)
      ((y: Nat) => (z: Nat) => refl zero);
  multiplyComm x x
}
val localRing : Eq Nat zero zero = viaRing zero
val localMultiply : Eq Nat zero zero = multiplyViaRing zero
'''),
      );
      expect(_ctorName(_evalBinding(ring, 'localRing')), 'refl');
      expect(_ctorName(_evalBinding(ring, 'localMultiply')), 'refl');
    });

    test('the bare addComm is ambiguous across the declaring classes', () {
      // `AddCommMonoid`, `AddCommGroup`, and `CommRing` each declare
      // `addComm`. With no local dictionary and no top-level binding, the
      // bare name reports every candidate.
      expect(
        () => checkProgram(
          pp('''
$_prelude
$classes
val bad: Eq Nat zero zero = addComm zero zero
'''),
        ),
        throwsA(
          isA<AmbiguousClassMethod>()
              .having((e) => e.methodName, 'methodName', 'addComm')
              .having(
                (e) => e.candidates,
                'candidates',
                containsAll(<String>[
                  'AddCommMonoid.addComm',
                  'AddCommGroup.addComm',
                  'CommRing.addComm',
                ]),
              ),
        ),
      );
    });

    test('the class-qualified addComm and multiplyComm resolve', () {
      final env = checkProgram(
        pp('''
$_prelude
$classes
impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = zero;
}
impl AddGroup[Nat] {
  fun negate(x: Nat): Nat = zero;
}
impl Ring[Nat] {
  fun multiply(x: Nat, y: Nat): Nat = zero;
}
impl AddCommMonoid[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
impl AddCommGroup[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
impl CommRing[Nat] {
  fun addComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
  fun multiplyComm(x: Nat, y: Nat): Eq Nat zero zero = refl zero;
}
val monoidQualified : Eq Nat zero zero = AddCommMonoid.addComm zero zero
val groupQualified : Eq Nat zero zero = AddCommGroup.addComm zero zero
val ringAddQualified : Eq Nat zero zero = CommRing.addComm zero zero
val ringMultiplyQualified : Eq Nat zero zero = CommRing.multiplyComm zero zero
'''),
      );

      expect(_ctorName(_evalBinding(env, 'monoidQualified')), 'refl');
      expect(_ctorName(_evalBinding(env, 'groupQualified')), 'refl');
      expect(_ctorName(_evalBinding(env, 'ringAddQualified')), 'refl');
      expect(_ctorName(_evalBinding(env, 'ringMultiplyQualified')), 'refl');
    });
  });
}
