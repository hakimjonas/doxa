/// Typeclass elaboration: dictionary types, projections, instances, and
/// instance search.
library;

import 'package:doxa/src/check.dart' show TypeMismatch;
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
''';

/// Single-method class used throughout.
const _eqbClass = '''
typeclass Eqb[A: Type] {
  fun equals(x: A, y: A): Bool;
}
''';

String _program(String body) => '$_prelude\n$_eqbClass\n$body';

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
  group('typeclass declarations', () {
    test('elaborates to a dictionary type and a projection', () {
      final env = checkProgram(pp(_program('')));

      final data = env.lookupData('Eqb');
      expect(data, isNotNull);
      expect(data!.params.length, 1);
      expect(data.ctors.length, 1);
      final ctor = data.ctors.single;
      expect(ctor.name, 'mkEqb');
      expect(ctor.args.length, 1);
      expect(ctor.args.single.name, 'equals');

      final projections =
          env.bindings.where((b) => b.name == 'Eqb.equals').toList();
      expect(projections.length, 1);

      // {A: Type} -> (x: A) -> (y: A) -> {inst: Eqb A} -> Bool
      final type = projections.single.type;
      expect(type, isA<TPi>());
      final pA = type as TPi;
      expect(pA.icit, Icit.implicit);
      expect(pA.domain, const TType(LLevel(0)));
      final pX = pA.codomain as TPi;
      expect(pX.icit, Icit.explicit);
      final pY = pX.codomain as TPi;
      expect(pY.icit, Icit.explicit);
      final pInst = pY.codomain as TPi;
      expect(pInst.icit, Icit.implicit);
      expect(pInst.domain, isA<TData>());
      final instDomain = pInst.domain as TData;
      expect(instDomain.name, 'Eqb');
      expect(instDomain.args.length, 1);
      expect(pInst.codomain, const TData('Bool', <Term>[]));
    });
  });

  group('instances', () {
    test('impl registers an instance and a call reduces through it', () {
      final env = checkProgram(
        pp(
          _program('''
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}
val r: Bool = equals zero zero
'''),
        ),
      );

      final classInfo = env.classRegistry['Eqb']!;
      expect(classInfo.instances.length, 1);
      expect(classInfo.instances.single.targetHead, 'Nat');
      expect(classInfo.instances.single.bindingName, '_impl_Eqb_Nat');
      expect(
        env.bindings.any((b) => b.name == '_impl_Eqb_Nat'),
        isTrue,
        reason: 'the instance value is an ordinary top-level binding',
      );
      expect(_ctorName(_evalBinding(env, 'r')), 'true_');
    });

    test('a constrained parameter resolves for Nat and Bool', () {
      final env = checkProgram(
        pp(
          _program('''
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}
impl Eqb[Bool] {
  fun equals(x: Bool, y: Bool): Bool = match x {
    case true_ => y
    case false_ => false_
  };
}
fun same[A: Eqb](x: A, y: A): Bool = equals x y
val natSame: Bool = same Nat zero zero
val boolSame: Bool = same Bool true_ true_
'''),
        ),
      );

      // The constrained type parameter keeps the icity of its group, so
      // A is explicit. The dictionary follows the explicit parameters.
      final same = env.bindings.firstWhere((b) => b.name == 'same');
      final pA = same.type as TPi;
      expect(pA.icit, Icit.explicit);
      final pX = pA.codomain as TPi;
      expect(pX.icit, Icit.explicit);
      final pY = pX.codomain as TPi;
      expect(pY.icit, Icit.explicit);
      final pInst = pY.codomain as TPi;
      expect(pInst.icit, Icit.implicit);
      expect((pInst.domain as TData).name, 'Eqb');

      expect(_ctorName(_evalBinding(env, 'natSame')), 'true_');
      expect(_ctorName(_evalBinding(env, 'boolSame')), 'true_');
    });

    test('a missing explicit type argument fails at the first value', () {
      // `same zero zero` mirrors `id zero`: the explicit type parameter
      // receives zero, and the value parameter then checks it against
      // Type. Pin both spans so the diagnostic is part of the contract.
      final sameSource = _program('''
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = true_;
}
fun same[A: Eqb](x: A, y: A): Bool = equals x y
val natSame: Bool = same zero zero
''');
      final sameZero = sameSource.indexOf(
        'zero',
        sameSource.indexOf('same zero'),
      );
      expect(
        () => checkProgram(pp(sameSource)),
        throwsA(
          isA<TypeMismatch>().having(
            (e) => e.span,
            'span',
            DoxaSpan(sameZero, sameZero + 'zero'.length),
          ),
        ),
      );

      const idSource = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
fun id[A: Type](x: A): A = x
val c : Nat = id zero
''';
      final idZero = idSource.indexOf('zero', idSource.indexOf('id zero'));
      expect(
        () => checkProgram(pp(idSource)),
        throwsA(
          isA<TypeMismatch>().having(
            (e) => e.span,
            'span',
            DoxaSpan(idZero, idZero + 'zero'.length),
          ),
        ),
      );
    });

    test('a second instance for the same class and head is rejected', () {
      final source = _program('''
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = true_;
}
impl Eqb[Nat] {
  fun equals(x: Nat, y: Nat): Bool = false_;
}
''');
      final second = source.lastIndexOf('impl Eqb[Nat]');
      expect(
        () => checkProgram(pp(source)),
        throwsA(
          isA<OverlappingInstances>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Nat')
              .having((e) => e.span, 'span', DoxaSpan(second, source.length)),
        ),
      );
    });
  });

  group('instance search failures', () {
    test('a missing instance at top level names the class and type', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
data Color : Type { red : Color; blue : Color; }
val bad: Bool = equals red red
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Color'),
        ),
      );
    });

    test('a missing instance points the span at the use site', () {
      final source = _program('''
data Color : Type { red : Color; blue : Color; }
val bad: Bool = equals red red
''');
      final use = source.indexOf('equals red red');
      expect(
        () => checkProgram(pp(source)),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Color')
              .having(
                (e) => e.span,
                'span',
                DoxaSpan(use, use + 'equals red red'.length),
              ),
        ),
      );
    });

    test('a missing instance in a block tail points the span at the call', () {
      final source = _program('''
fun useEqb[A: Eqb](x: A, y: A): Bool = equals x y
fun f(x: Nat, y: Nat): Bool = {
  val k : Bool = true_;
  useEqb Nat x y
}
''');
      final use = source.indexOf('useEqb Nat x y');
      expect(
        () => checkProgram(pp(source)),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', 'Nat')
              .having(
                (e) => e.span,
                'span',
                DoxaSpan(use, use + 'useEqb Nat x y'.length),
              ),
        ),
      );
    });

    test('a missing instance inside a by-checked declaration is reported', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
data Color : Type { red : Color; blue : Color; }
fun idBool(b: Bool): Bool = b
theorem bad : Bool := by { exact idBool (equals red red) }
'''),
          ),
        ),
        throwsA(
          isA<NoInstanceFound>().having((e) => e.className, 'className', 'Eqb'),
        ),
      );
    });
  });

  group('instance targets', () {
    const listData = '''
data List[A: Type] : Type {
  nil : List A;
  cons : A -> List A -> List A;
}
''';

    test('a closed applied target is rejected', () {
      expect(
        () => checkProgram(
          pp('''
$_prelude
$_eqbClass
$listData
impl Eqb[List Nat] {
  fun equals(x: List Nat, y: List Nat): Bool = true_;
}
'''),
        ),
        throwsA(
          isA<UnsupportedInstanceTarget>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.reason, 'reason', contains('closed argument')),
        ),
      );
    });

    test('a call at an unregistered instantiation reports the class and '
        'type', () {
      expect(
        () => checkProgram(
          pp('''
$_prelude
$_eqbClass
$listData
val xs: List Bool = nil
val bad: Bool = equals xs xs
'''),
        ),
        throwsA(
          isA<NoInstanceFound>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.targetType, 'targetType', contains('List'))
              .having((e) => e.targetType, 'targetType', contains('Bool')),
        ),
      );
    });
  });

  group('class declarations', () {
    test('two classes may share a method name', () {
      final env = checkProgram(
        pp('''
$_prelude
typeclass ShowA[A: Type] {
  fun show(x: A): Bool;
}
typeclass ShowB[A: Type] {
  fun show(x: A): Bool;
}
'''),
      );
      // The projections are class-qualified, so the bare name is free
      // and each class keeps its own projection.
      expect(env.bindings.where((b) => b.name == 'ShowA.show'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'ShowB.show'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'show'), isEmpty);
    });

    test('one class cannot declare a method twice', () {
      expect(
        () => checkProgram(
          pp('''
$_prelude
typeclass Twice[A: Type] {
  fun show(x: A): Bool;
  fun show(x: A): Bool;
}
'''),
        ),
        throwsA(
          isA<DuplicateDeclaration>()
              .having((e) => e.name, 'name', 'show')
              .having(
                (e) => e.previousSpan.start < e.span.start,
                'previous span precedes the redeclaration',
                isTrue,
              )
              .having(
                (e) => e.previousSpan.isSynthetic || e.span.isSynthetic,
                'both spans are source spans',
                isFalse,
              ),
        ),
      );
    });
  });

  group('rejected forms', () {
    test('a superclass is recorded and embedded as the first field', () {
      final env = checkProgram(
        pp('''
$_prelude
$_eqbClass
typeclass Ord[A: Type]: Eqb[A] {
  fun cmp(x: A, y: A): Bool;
}
'''),
      );
      final ord = env.classRegistry['Ord']!;
      expect(ord.superclassName, 'Eqb');
      expect(ord.superclassParameters, ['A']);
      final data = env.lookupData('Ord')!;
      expect(data.params.length, 1);
      expect(data.ctors.single.args.length, 2);
      expect(data.ctors.single.args.first.name, '_super');
      expect(data.ctors.single.args.last.name, 'cmp');
    });

    test('a partial instance is rejected naming the missing method', () {
      expect(
        () => checkProgram(pp(_program('impl Eqb[Nat] { }'))),
        throwsA(
          isA<MissingInstanceMethod>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.methodName, 'methodName', 'equals'),
        ),
      );
    });

    test('an unknown method is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
impl Eqb[Nat] {
  fun nope(x: Nat, y: Nat): Bool = true_;
}
'''),
          ),
        ),
        throwsA(
          isA<UnknownInstanceMethod>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.methodName, 'methodName', 'nope'),
        ),
      );
    });

    test('an unknown class is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
impl Nope[Nat] {
  fun equals(x: Nat, y: Nat): Bool = true_;
}
'''),
          ),
        ),
        throwsA(
          isA<UnknownTypeclass>().having(
            (e) => e.className,
            'className',
            'Nope',
          ),
        ),
      );
    });

    test('a wrong number of class arguments is rejected', () {
      expect(
        () => checkProgram(
          pp(
            _program('''
impl Eqb {
  fun equals(x: Nat, y: Nat): Bool = true_;
}
'''),
          ),
        ),
        throwsA(
          isA<TypeclassArityMismatch>()
              .having((e) => e.className, 'className', 'Eqb')
              .having((e) => e.expected, 'expected', 1)
              .having((e) => e.got, 'got', 0),
        ),
      );
    });
  });

  group('multi-method classes', () {
    test('a two-method class elaborates both projections and reduces', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Both[A: Type] {
  fun f(x: A): A;
  fun g(x: A): A;
}
impl Both[Nat] {
  fun f(x: Nat): Nat = succ x;
  fun g(x: Nat): Nat = x;
}
val fz: Nat = f zero
val gz: Nat = g zero
'''),
        ),
      );

      final classInfo = env.classRegistry['Both']!;
      expect(classInfo.methods.length, 2);
      expect(env.bindings.where((b) => b.name == 'Both.f'), hasLength(1));
      expect(env.bindings.where((b) => b.name == 'Both.g'), hasLength(1));
      expect(_ctorName(_evalBinding(env, 'fz')), 'succ');
      expect(_ctorName(_evalBinding(env, 'gz')), 'zero');
    });

    test('method types mention the class parameter', () {
      final env = checkProgram(
        pp(
          _program('''
typeclass Nested[A: Type] {
  fun f(x: A): A;
  fun g(x: A): A -> A;
}
impl Nested[Nat] {
  fun f(x: Nat): Nat = x;
  fun g(x: Nat): Nat -> Nat = (y: Nat) => y;
}
val gz: Nat = g zero (succ zero)
'''),
        ),
      );

      expect(_ctorName(_evalBinding(env, 'gz')), 'succ');
    });
  });

  group('commutative class dictionaries', () {
    const eqData = '''
data Eq[A: Type]: A -> A -> Prop {
  refl: (x: A) -> Eq A x x;
}
''';

    const classes = '''
typeclass AddMonoid[A: Type] {
  fun add(x: A, y: A): A;
}
typeclass AddGroup[A: Type]: AddMonoid A {
  fun negate(x: A): A;
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

    test('the constructors put the parent first and the laws in order', () {
      final env = checkProgram(pp('$_prelude\n$eqData\n$classes'));

      expect(env.classRegistry['AddCommGroup']!.superclassName, 'AddGroup');
      final groupData = env.lookupData('AddCommGroup')!;
      final groupCtor = groupData.ctors.single;
      expect(groupCtor.name, 'mkAddCommGroup');
      expect(groupCtor.args.map((a) => a.name).toList(), ['_super', 'addComm']);

      expect(env.classRegistry['CommRing']!.superclassName, 'Ring');
      final ringData = env.lookupData('CommRing')!;
      final ringCtor = ringData.ctors.single;
      expect(ringCtor.name, 'mkCommRing');
      expect(ringCtor.args.map((a) => a.name).toList(), [
        '_super',
        'addComm',
        'multiplyComm',
      ]);
    });

    test('a CommRing dictionary constructs through mkCommRing', () {
      // The law field types name the parent `add` and `Ring`'s `multiply`.
      // A constant-zero `AddMonoid Nat` reduces both laws to
      // `Eq Nat zero zero`, so `refl` fills the two fields.
      final env = checkProgram(
        pp('''
$_prelude
$eqData
$classes
impl AddMonoid[Nat] {
  fun add(x: Nat, y: Nat): Nat = zero;
}
val d : CommRing Nat =
  mkCommRing
    (mkRing
      (mkAddGroup (mkAddMonoid ((y: Nat) => (z: Nat) => zero)) ((y: Nat) => y))
      ((y: Nat) => (z: Nat) => zero))
    ((y: Nat) => (z: Nat) => refl zero)
    ((y: Nat) => (z: Nat) => refl zero)
'''),
      );

      expect(_ctorName(_evalBinding(env, 'd')), 'mkCommRing');
    });
  });
}
