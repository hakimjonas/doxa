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
      // A dictionary in a local binder disambiguates the bare name, even
      // though both classes declare `tag`. The dictionary is an ordinary
      // value of the dictionary type, as `val` and instance search use.
      final env = checkProgram(
        pp('''
$_prelude
$_twoTags
fun withLeft(d: Left Nat, x: Nat): Nat = tag x
fun withRight(d: Right Nat, x: Nat): Nat = tag x
val localLeft: Nat = withLeft (mk_Left ((y: Nat) => zero)) (succ zero)
val localRight: Nat =
  withRight (mk_Right ((y: Nat) => succ y)) (succ zero)
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

  group('class law fields', () {
    const classes = '''
typeclass MulOnly[A: Type] {
  fun mul(x: A, y: A): A;
}
typeclass Base[A: Type] {
  fun add(x: A, y: A): A;
}
typeclass Ringy[A: Type]: Base A {
  fun mul(x: A, y: A): A;
  fun ownLaw(x: A): Eq A (mul x x) (mul x x);
  fun parentLaw(x: A): Eq A (add x x) (add x x);
}
''';

    test('a law reads its own method, then a parent method', () {
      // `mul` is declared by both `MulOnly` and `Ringy`, so the bare name
      // is ambiguous outside a class. Inside `Ringy`, the current class
      // wins for `mul`; `add` resolves through the parent `Base`.
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
  fun mul(x: Nat, y: Nat): Nat = succ x;
}
impl Base[Nat] {
  fun add(x: Nat, y: Nat): Nat = plus x y;
}
impl Ringy[Nat] {
  fun mul(x: Nat, y: Nat): Nat = plus x y;
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
}
