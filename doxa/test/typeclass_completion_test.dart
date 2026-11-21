/// Completed typeclass surface: superclasses, multi-parameter classes, and
/// local dictionaries.
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
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
''';

const _eqb = '''
typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}
''';

/// A true dictionary for Nat and a comparison helper.
const _eqbNat = '''
fun eqbNat(x: Nat, y: Nat): Bool = match x {
  case zero => match y {
    case zero => true_
    case succ _ => false_
  }
  case succ n => match y {
    case zero => false_
    case succ m => eqbNat n m
  }
}
''';

Value _evalBinding(TopEnv env, String name) {
  final binding = env.bindings.firstWhere((b) => b.name == name);
  return eval(binding.term, env.toCtx().env);
}

String _ctorName(Value value) {
  expect(value, isA<VConstr>());
  return (value as VConstr).ctorName;
}

String _program(String body) => '$_prelude\n$_eqb\n$_eqbNat\n$body';

void main() {
  group('superclasses', () {
    test('eq resolves through a local Ord constraint', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbNat x y;
}

fun eqViaOrd[A: Ord](x: A, y: A): Bool = eqb x y
val r : Bool = eqViaOrd Nat zero zero
'''),
        ),
      );

      final ord = env.classRegistry['Ord']!;
      expect(ord.superclassName, 'Eqb');
      expect(ord.superclassParameters, ['A']);
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a two-level chain derives the root dictionary', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

typeclass Ordered[A: Type]: Ord[A] {
  fun le(x: A, y: A): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl Ordered[Nat] {
  fun le(x: Nat, y: Nat): Bool = eqbNat x y;
}

fun eqViaOrdered[A: Ordered](x: A, y: A): Bool = eqb x y
val r : Bool = eqViaOrdered Nat zero zero
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a subclass instance without a parent is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbNat x y;
}
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

    test('a direct dictionary is preferred over a derived one', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

fun eqbFalse(x: Nat, y: Nat): Bool = false_
fun eqbTrue(x: Nat, y: Nat): Bool = true_

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbFalse x y;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbFalse x y;
}

fun viaBoth[A: Type](eqbD: Eqb A, ordD: Ord A, x: A): Bool = eqb x x

val r : Bool = viaBoth Nat (mk_Eqb eqbTrue) _impl_Ord_Nat zero
'''),
        ),
      );
      // The direct Eqb parameter wins; the Ord parent returns false.
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a registered direct instance is preferred over a derived one', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl Ord[Nat] {
  fun cmp(x: Nat, y: Nat): Bool = eqbNat x y;
}

val r : Bool = eqb zero zero
'''),
        ),
      );
      final term = env.bindings.firstWhere((b) => b.name == 'r').term;
      expect(term.toString(), contains('_impl_Eqb_Nat'));
      expect(term.toString(), isNot(contains('_super')));
    });

    test(
      'two subclass dictionaries providing the same parent are ambiguous',
      () {
        expect(
          () => checkProgram(
            pp(
              _program('''
typeclass OrdA[A: Type]: Eqb[A] {
  fun cmpa(x: A, y: A): Bool;
}

typeclass OrdB[A: Type]: Eqb[A] {
  fun cmpb(x: A, y: A): Bool;
}

fun f[A: OrdA & OrdB](x: A): Bool = eqb x x
'''),
            ),
          ),
          throwsA(
            isA<OverlappingInstances>()
                .having((e) => e.className, 'className', 'Eqb')
                .having(
                  (e) => e.instanceNames,
                  'instanceNames',
                  contains('OrdA'),
                )
                .having(
                  (e) => e.instanceNames,
                  'instanceNames',
                  contains('OrdB'),
                ),
          ),
        );
      },
    );

    test('a parameterised parent is derived from a local dictionary', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Rel[A: Type, B: Type] {
  fun rel(x: A, y: B): Bool;
}

typeclass C2[A: Type, B: Type]: Rel[A, B] {
  fun c2(x: A, y: B): Bool;
}

fun relTrue(x: Nat, y: Bool): Bool = true_
fun c2Nat(x: Nat, y: Bool): Bool = true_

impl Rel[Nat, Bool] {
  fun rel(x: Nat, y: Bool): Bool = relTrue x y;
}

impl C2[Nat, Bool] {
  fun c2(x: Nat, y: Bool): Bool = c2Nat x y;
}

fun relViaC2[A: Type, B: Type](d: C2[A, B], x: A, y: B): Bool = rel x y

val r : Bool = relViaC2 Nat Bool _impl_C2_Nat_Bool zero true_
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });
  });

  group('multi-parameter classes', () {
    test('a concrete two-parameter instance is selected', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Convert[A: Type, B: Type] {
  fun conv(x: A, y: B): B;
}

impl Convert[Nat, Bool] {
  fun conv(x: Nat, y: Bool): Bool = y;
}

val r : Bool = conv zero true_
'''),
        ),
      );
      final info = env.classRegistry['Convert']!.instances.single;
      expect(info.targetHeads, ['Nat', 'Bool']);
      expect(info.targetArities, [0, 0]);
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a generic instance for bare parameters is accepted', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Pair[A: Type, B: Type] {
  fun fst(x: A, y: B): A;
}

impl[A: Type, B: Type] Pair[A, B] {
  fun fst(x: A, y: B): A = x;
}

val r : Nat = fst zero true_
'''),
        ),
      );
      final info = env.classRegistry['Pair']!.instances.single;
      expect(info.targetHeads, ['*', '*']);
      expect(info.targetWildcards, ['A', 'B']);
      expect(_ctorName(_evalBinding(env, 'r')), 'zero');
    });

    test('a constrained parameter is discharged for the goal', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Pair[A: Type, B: Type] {
  fun bothEq(x: A, y: B): Bool;
}

impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}

impl[A: Eqb, B: Type] Pair[A, B] {
  fun bothEq(x: A, y: B): Bool = eqb x x;
}

val r : Bool = bothEq zero true_
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('the second target argument selects a distinct instance', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Tag[A: Type, B: Type] {
  fun tag(x: A, y: B): B;
}

impl Tag[Nat, Bool] {
  fun tag(x: Nat, y: Bool): Bool = y;
}

impl Tag[Nat, Nat] {
  fun tag(x: Nat, y: Nat): Nat = y;
}

val toBool : Bool = tag zero true_
val toNat : Nat = tag zero zero
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'toBool')), 'true_');
      expect(_ctorName(_evalBinding(env, 'toNat')), 'zero');
    });

    test('a mismatch at the second argument is not an instance', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Tag[A: Type, B: Type] {
  fun tag(x: A, y: B): B;
}

impl Tag[Nat, Bool] {
  fun tag(x: Nat, y: Bool): Bool = y;
}

val bad : Nat = tag zero zero
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Tag')
              .having((e) => e.targetType, 'targetType', 'Tag Nat Nat'),
        ),
      );
    });

    test(
      'a target argument that is applied instead of bare is not an instance',
      () {
        expect(
          () => checkProgram(
            pp(
              _program('''
data Box[A: Type] : Type {
  box : A -> Box A;
}

typeclass Tag[A: Type, B: Type] {
  fun tag(x: A, y: B): B;
}

impl Tag[Nat, Bool] {
  fun tag(x: Nat, y: Bool): Bool = y;
}

val bad : Bool = tag zero (box zero)
'''),
            ),
          ),
          throwsA(
            isA<NoInstanceFound>()
                .having((e) => e.className, 'className', 'Tag')
                .having(
                  (e) => e.targetType,
                  'targetType',
                  allOf(contains('Nat'), contains('Box')),
                ),
          ),
        );
      },
    );

    test('a duplicate target tuple is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Tag[A: Type, B: Type] {
  fun tag(x: A, y: B): B;
}

impl Tag[Nat, Bool] {
  fun tag(x: Nat, y: Bool): Bool = true_;
}

impl Tag[Nat, Bool] {
  fun tag(x: Nat, y: Bool): Bool = false_;
}
'''),
          ),
        ),
        throwsA(
          isA<OverlappingInstances>()
              .having((e) => e.className, 'className', 'Tag')
              .having((e) => e.targetType, 'targetType', 'Tag Nat Bool'),
        ),
      );
    });

    test('a wildcard and a concrete instance are ambiguous at search', () {
      final registered = checkProgram(
        pp(
          _program('''
typeclass C[A: Type, B: Type] {
  fun f(x: A, y: B): B;
}

impl[A: Type, B: Type] C[A, B] {
  fun f(x: A, y: B): B = y;
}

impl C[Nat, Bool] {
  fun f(x: Nat, y: Bool): Bool = y;
}
'''),
        ),
      );
      final instances = registered.classRegistry['C']!.instances;
      expect(instances.length, 2);
      expect(
        instances.where((i) => i.targetHeads.join(',') == '*,*').length,
        1,
      );
      expect(
        instances.where((i) => i.targetHeads.join(',') == 'Nat,Bool').length,
        1,
      );

      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass C[A: Type, B: Type] {
  fun f(x: A, y: B): B;
}

impl[A: Type, B: Type] C[A, B] {
  fun f(x: A, y: B): B = y;
}

impl C[Nat, Bool] {
  fun f(x: Nat, y: Bool): Bool = y;
}

val r : Bool = f zero true_
'''),
          ),
        ),
        throwsA(
          isA<OverlappingInstances>()
              .having((e) => e.className, 'className', 'C')
              .having((e) => e.targetType, 'targetType', 'C Nat Bool')
              .having(
                (e) => e.instanceNames,
                'instanceNames',
                contains('_impl_C_any_any'),
              )
              .having(
                (e) => e.instanceNames,
                'instanceNames',
                contains('_impl_C_Nat_Bool'),
              ),
        ),
      );
    });
  });

  group('restrictions', () {
    test('a default method body is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Show[A: Type] {
  fun show(x: A): Bool = true_;
}
'''),
          ),
        ),
        throwsA(
          isA<TypeclassUnsupported>().having(
            (e) => e.reason,
            'reason',
            contains('default bodies'),
          ),
        ),
      );
    });

    test('a repeated superclass parameter is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Rel[A: Type, B: Type] {
  fun rel(x: A, y: B): Bool;
}

typeclass Ord[A: Type]: Rel[A, A] {
  fun cmp(x: A, y: A): Bool;
}
'''),
          ),
        ),
        throwsA(
          isA<TypeclassUnsupported>().having(
            (e) => e.reason,
            'reason',
            contains('repeats the class parameter'),
          ),
        ),
      );
    });

    test(
      'an instance parameter that is absent from the target is rejected',
      () {
        expect(
          () => checkProgram(
            pp(
              _program('''
typeclass Pair[A: Type, B: Type] {
  fun fst(x: A, y: B): A;
}

impl[A: Type, B: Type] Pair[A, Nat] {
  fun fst(x: A, y: Nat): A = x;
}
'''),
            ),
          ),
          throwsA(
            isA<UnsupportedInstanceTarget>().having(
              (e) => e.reason,
              'reason',
              contains('does not appear in the target'),
            ),
          ),
        );
      },
    );

    test('a superclass applied to a non-parameter is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
typeclass Ord[A: Type]: Eqb[Nat] {
  fun cmp(x: A, y: A): Bool;
}
'''),
          ),
        ),
        throwsA(
          isA<TypeclassUnsupported>().having(
            (e) => e.reason,
            'reason',
            contains('class type parameters'),
          ),
        ),
      );
    });
  });

  group('local dictionaries', () {
    test('a local val of the dictionary type supplies the instance', () {
      final env = checkProgram(
        pp(
          _program('''
fun useEqb[A: Eqb](x: A, y: A): Bool = eqb x y

fun localEq(x: Nat, y: Nat): Bool = {
  val d : Eqb Nat = mk_Eqb eqbNat;
  val r : Bool = useEqb Nat x y;
  r
}

val r : Bool = localEq zero zero
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a local subclass dictionary derives its parent', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}

fun cmpNat(x: Nat, y: Nat): Bool = true_
fun useEqb[A: Eqb](x: A, y: A): Bool = eqb x y

fun localOrd(x: Nat, y: Nat): Bool = {
  val d : Ord Nat = mk_Ord (mk_Eqb eqbNat) cmpNat;
  val r : Bool = useEqb Nat x y;
  r
}

val r : Bool = localOrd zero zero
'''),
        ),
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a local dictionary does not escape its binding', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
fun useEqb[A: Eqb](x: A, y: A): Bool = eqb x y

fun localEq(x: Nat, y: Nat): Bool = {
  val d : Eqb Nat = mk_Eqb eqbNat;
  val r : Bool = useEqb Nat x y;
  r
}

fun leak(x: Nat, y: Nat): Bool = useEqb Nat x y
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
  });
}
