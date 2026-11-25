/// Parameterised instances: `impl[A: Eqb] Eqb[List A]`, template matching,
/// and recursive constraint discharge.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
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

/// Minimal prelude for these tests.
const _prelude = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data List[A: Type] : Type { nil : List A; cons : A -> List A -> List A; }
data Pair[A: Type, B: Type] : Type { pair : A -> B -> Pair A B; }
''';

const _eqbClass = '''
typeclass Eqb[A: Type] {
  fun equals(x: A, y: A): Bool;
}
''';

const _andb = '''
fun andb(a: Bool, b: Bool): Bool = match a {
  case true_ => b
  case false_ => false_
}
''';

/// Structural helper for the Nat instance.
const _natHelper = '''
fun equalsNat(x: Nat, y: Nat): Bool = match x {
  case zero => match y {
    case zero => true_
    case succ _ => false_
  }
  case succ n => match y {
    case zero => false_
    case succ m => equalsNat n m
  }
}
''';

const _natInstance = '''
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = equalsNat x y;
}
''';

/// Structural helper for the List instance.
///
/// The helper carries the class constraint, so `equals` on the element type
/// uses its dictionary. The tail call passes the explicit type argument;
/// the structural check counts it before comparing the designated value
/// position. The instance delegates to this function because a method body
/// cannot resolve its own instance.
const _listHelper = '''
fun equalsList[A: Eqb](xs: List A, ys: List A): Bool {struct xs} = match xs {
  case nil => match ys {
    case nil => true_
    case cons _ _ => false_
  }
  case cons h t => match ys {
    case nil => false_
    case cons h2 t2 => andb (equals h h2) (equalsList A t t2)
  }
}
''';

const _listInstance = '''
impl[A: Eqb] Eqb[List A] {
  fun equals(x: List A, y: List A): Bool = equalsList A x y;
}
''';

String _program(String body) =>
    '$_prelude\n$_eqbClass\n$_andb\n$_natHelper\n$_listHelper\n$body';

/// Evaluate a named top-level binding in [env].
Value _evalBinding(TopEnv env, String name) {
  final binding = env.bindings.firstWhere((b) => b.name == name);
  return eval(binding.term, env.toCtx().env);
}

String _ctorName(Value value) {
  expect(value, isA<VConstr>());
  return (value as VConstr).ctorName;
}

void main() {
  group('parameterised instances', () {
    test('a List instance is a binding with explicit parameters and '
        'reduces at List Nat', () {
      final env = checkProgram(
        pp(
          _program('''
$_natInstance
$_listInstance
val r: Bool = equals (cons zero nil) (cons zero nil)
'''),
        ),
      );

      final list = env.bindings.firstWhere((b) => b.name == '_impl_Eqb_List');
      // (A: Type) -> (inst: Eqb A) -> Eqb (List A)
      final pA = list.type as TPi;
      expect(pA.icit, Icit.explicit);
      expect(pA.domain, const TType(LLevel(0)));
      final pDict = pA.codomain as TPi;
      expect(pDict.icit, Icit.explicit);
      final dictType = pDict.domain as TData;
      expect(dictType.name, 'Eqb');
      final resultType = pDict.codomain as TData;
      expect(resultType.name, 'Eqb');
      expect((resultType.args.single as TData).name, 'List');

      final info = env.classRegistry['Eqb']!.instances.firstWhere(
        (i) => i.targetHead == 'List',
      );
      expect(info.targetParameters, ['A']);
      expect(info.parameters, ['A']);
      expect(info.constraints.length, 1);
      expect(info.constraints.single.className, 'Eqb');
      expect(info.constraints.single.parameterName, 'A');

      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('the helper-based instance recurses on the tail and reduces', () {
      final env = checkProgram(
        pp(
          _program('''
$_natInstance
$_listInstance
val r: Bool = equals (cons zero (cons zero nil)) (cons zero (cons zero nil))
'''),
        ),
      );

      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('nested lists resolve through the same instance twice', () {
      final env = checkProgram(
        pp(
          _program('''
$_natInstance
$_listInstance
val r: Bool = equals (cons (cons zero nil) nil) (cons (cons zero nil) nil)
'''),
        ),
      );

      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a missing element instance names the inner class and type', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
$_listInstance
val xs: List Bool = nil
val bad: Bool = equals xs xs
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Bool'),
        ),
      );
    });

    test('a List instance does not match a Nat goal', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
$_listInstance
val bad: Bool = equals zero zero
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Nat'),
        ),
      );
    });

    test('a second List instance is rejected as overlapping', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
$_listInstance
$_listInstance
'''),
          ),
        ),
        throwsA(
          isA<OverlappingInstances>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', contains('List')),
        ),
      );
    });

    test('invalid target shapes are rejected with their reasons', () {
      Matcher rejects(String reason) => throwsA(
        isA<UnsupportedInstanceTarget>()
            .having((e) => e.className, 'className', 'Eqb')
            .having((e) => e.reason, 'reason', contains(reason)),
      );

      // A bare variable target gives search no head to key on.
      expect(
        () => checkProgram(
          pp(
            _program('''
impl[A: Eqb] Eqb[A] {
  fun equals(x: A, y: A): Bool = true_;
}
'''),
          ),
        ),
        rejects('would not make progress'),
      );

      // A closed argument would duplicate a parameterised instance.
      expect(
        () => checkProgram(
          pp(
            _program('''
impl Eqb[List Nat] {
  fun equals(x: List Nat, y: List Nat): Bool = true_;
}
'''),
          ),
        ),
        rejects('closed argument'),
      );

      // A repeated parameter would need consistency checking.
      expect(
        () => checkProgram(
          pp(
            _program('''
impl[A: Eqb] Eqb[Pair A A] {
  fun equals(x: Pair A A, y: Pair A A): Bool = true_;
}
'''),
          ),
        ),
        rejects('repeats'),
      );
    });

    test('a chain deeper than the bound reports the depth diagnostic', () {
      var deep = 'Nat';
      for (var i = 0; i < 9; i++) {
        deep = 'List ($deep)';
      }
      final source = _program('''
$_natInstance
$_listInstance
val deep: $deep = nil
val bad: Bool = equals deep deep
''');
      final use = source.indexOf('equals deep deep');
      expect(
        () => checkProgram(pp(source)),
        throwsA(
          isA<InstanceSearchDepthExceeded>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.depth, 'depth', 8)
              .having(
                (e) => e.span,
                'span',
                DoxaSpan(use, use + 'equals deep deep'.length),
              ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('the instance body uses the element dictionary, including through '
        'a constrained call', () {
      final env = checkProgram(
        pp(
          _program('''
$_natInstance
$_listInstance
fun sameList[A: Eqb](xs: List A, ys: List A): Bool = equals xs ys
val r: Bool = sameList Nat (cons zero nil) (cons zero nil)
'''),
        ),
      );

      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });
  });

  group('instance self-resolution', () {
    test('a bare instance body cannot resolve its own instance', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
data Void : Type {}
typeclass Boom[A: Type] {
  fun boom(x: A): Void;
}
impl Boom[Nat] {
  fun boom(x: Nat): Void = boom x;
}
val v : Void = boom zero
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Boom')
              .having((e) => e.targetType, 'targetType', 'Nat'),
        ),
      );
    });

    test('a parameterised instance body cannot resolve its own instance', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
data Void : Type {}
typeclass Boom[A: Type] {
  fun boom(x: A): Void;
}
impl[A: Type] Boom[List A] {
  fun boom(x: List A): Void = boom x;
}
val xs : List Nat = nil
val v : Void = boom xs
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Boom')
              .having((e) => e.targetType, 'targetType', 'List A'),
        ),
      );
    });
  });
}
