/// Type inference for TData and TConstr.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _elab(String src) => elabProgram(_parse(src));

/// Elaborate the program then type-check every binding it produced.
/// Returns the final TopEnv. Throws if any check fails. Drives the same
/// `elabDecl` + `checkDeclResult` path as the CLI so solved metavariables
/// are inlined into the finalized terms before checking.
TopEnv _elabAndCheck(String src) {
  final prog = _parse(src);
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final finalized = checkDeclResult(TopEnv(bindings, runningData), produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
  return TopEnv(bindings, dataDecls);
}

// ---------------------------------------------------------------------------
// Structural-inspection helpers.
// ---------------------------------------------------------------------------

void _expectVType(Value v, Level level) {
  expect(v, isA<VType>());
  expect((v as VType).level, level);
}

void _expectVData(Value v, String name, {int? argCount}) {
  expect(v, isA<VData>());
  expect((v as VData).name, name);
  if (argCount != null) {
    expect(v.args, hasLength(argCount));
  }
}

void _expectVConstr(
  Value v,
  String dataName,
  String ctorName, {
  int? argCount,
}) {
  expect(v, isA<VConstr>());
  final c = v as VConstr;
  expect(c.dataName, dataName);
  expect(c.ctorName, ctorName);
  if (argCount != null) {
    expect(c.args, hasLength(argCount));
  }
}

void main() {
  group('TData inference: basic cases', () {
    test('nullary Nat has type Type 0', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final v = infer(ctx, const TData('Nat', <Term>[]));
      _expectVType(v, const LLevel(0));
    });

    test('List applied to its param yields Type 0', () {
      final env = _elab('''
data Nat : Type { zero : Nat; }
data List[A: Type] : Type { nil : List[A]; }
''');
      final ctx = env.toCtx();
      final v = infer(ctx, const TData('List', [TData('Nat', <Term>[])]));
      _expectVType(v, const LLevel(0));
    });

    test('Prop-sorted data yields Prop', () {
      final env = _elab('data True : Prop { tt : True; }');
      final ctx = env.toCtx();
      final v = infer(ctx, const TData('True', <Term>[]));
      expect(v, isA<VProp>());
    });
  });

  group('TData inference: errors', () {
    test('unknown data name', () {
      final ctx = _elab('data Nat : Type { zero : Nat; }').toCtx();
      expect(
        () => infer(ctx, const TData('Bogus', <Term>[])),
        throwsA(isA<UnknownDataOrCtor>()),
      );
    });

    test('wrong arity (too few)', () {
      final env = _elab('data List[A: Type] : Type { nil : List[A]; }');
      expect(
        () => infer(env.toCtx(), const TData('List', <Term>[])),
        throwsA(
          isA<InductiveArityMismatch>()
              .having((e) => e.dataName, 'dataName', 'List')
              .having((e) => e.gotArity, 'gotArity', 0)
              .having((e) => e.expectedArity, 'expectedArity', 1),
        ),
      );
    });

    test('wrong arity (too many)', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      expect(
        () => infer(env.toCtx(), const TData('Nat', [TType(LLevel(0))])),
        throwsA(isA<InductiveArityMismatch>()),
      );
    });
  });

  group('TConstr inference: basic cases', () {
    test('nullary zero has type Nat', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final v = infer(ctx, const TConstr('Nat', 'zero', <Term>[]));
      _expectVData(v, 'Nat', argCount: 0);
    });

    test('succ zero has type Nat', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final ctx = env.toCtx();
      final v = infer(
        ctx,
        const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
      );
      _expectVData(v, 'Nat', argCount: 0);
    });

    test('nil[Nat] has type List[Nat]', () {
      final env = _elab('''
data Nat : Type { zero : Nat; }
data List[A: Type] : Type {
  nil : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      final ctx = env.toCtx();
      final v = infer(
        ctx,
        const TConstr('List', 'nil', [TData('Nat', <Term>[])]),
      );
      _expectVData(v, 'List', argCount: 1);
      _expectVData((v as VData).args.first, 'Nat', argCount: 0);
    });

    test('cons zero nil has type List[Nat]', () {
      final env = _elab('''
data Nat : Type { zero : Nat; }
data List[A: Type] : Type {
  nil : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      final ctx = env.toCtx();
      final v = infer(
        ctx,
        const TConstr('List', 'cons', [
          TData('Nat', <Term>[]),
          TConstr('Nat', 'zero', <Term>[]),
          TConstr('List', 'nil', [TData('Nat', <Term>[])]),
        ]),
      );
      _expectVData(v, 'List', argCount: 1);
      _expectVData((v as VData).args.first, 'Nat', argCount: 0);
    });
  });

  group('TConstr inference: indexed families', () {
    test('vnil[Nat] has type Vec[Nat] zero', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      final ctx = env.toCtx();
      final v = infer(
        ctx,
        const TConstr('Vec', 'vnil', [TData('Nat', <Term>[])]),
      );
      _expectVData(v, 'Vec', argCount: 2);
      final vd = v as VData;
      _expectVData(vd.args[0], 'Nat', argCount: 0);
      _expectVConstr(vd.args[1], 'Nat', 'zero', argCount: 0);
    });

    test('vcons[Nat, zero, zero, vnil[Nat]] has type Vec[Nat] (succ zero)', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      final ctx = env.toCtx();
      final v = infer(
        ctx,
        const TConstr('Vec', 'vcons', [
          TData('Nat', <Term>[]), // A
          TConstr('Nat', 'zero', <Term>[]), // n
          TConstr('Nat', 'zero', <Term>[]), // head
          TConstr('Vec', 'vnil', [TData('Nat', <Term>[])]), // tail
        ]),
      );
      _expectVData(v, 'Vec', argCount: 2);
      final vd = v as VData;
      _expectVData(vd.args[0], 'Nat', argCount: 0);
      // succ zero
      _expectVConstr(vd.args[1], 'Nat', 'succ', argCount: 1);
      final succArg = (vd.args[1] as VConstr).args.first;
      _expectVConstr(succArg, 'Nat', 'zero', argCount: 0);
    });
  });

  group('end-to-end: val bindings referencing inductives type-check', () {
    test('val x: Nat = zero', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val x : Nat = zero
''');
      // Bindings: Nat.rec + Nat.ind (auto-emitted for Type-sorted
      // data) + user's `x`.
      expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind', 'x']);
    });

    test('val three: Nat = succ (succ (succ zero))', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val three : Nat = succ (succ (succ zero))
''');
      expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind', 'three']);
    });

    test('val xs: List[Nat] = cons zero nil', () {
      final env = _elabAndCheck('''
data Nat : Type { zero : Nat; }
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

val xs : List[Nat] = cons zero nil
''');
      expect(env.bindings.map((b) => b.name), [
        'Nat.rec',
        'Nat.ind',
        'List.rec',
        'List.ind',
        'xs',
      ]);
    });
  });

  group('unannotated lambda (check mode against a Pi)', () {
    test('val f: Nat -> Nat = (x) => succ x checks', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val f : Nat -> Nat = (x) => succ x
val two : Nat = f (succ zero)
''');
      expect(env.bindings.map((b) => b.name), [
        'Nat.rec',
        'Nat.ind',
        'f',
        'two',
      ]);
    });

    test('unannotated lambda in infer mode is rejected', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val bad = (x) => succ x
'''),
        throwsA(isA<LambdaRequiresAnnotation>()),
      );
    });
  });

  group('unannotated local block binding (inferred from bound expr)', () {
    test('{ val a = zero; succ a } checks', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val r : Nat = { val a = zero; succ a }
''');
      expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind', 'r']);
    });

    test('inferred binding usable by a later annotated binding', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val r : Nat = { val a = zero; val b : Nat = succ a; succ b }
''');
      expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind', 'r']);
    });
  });

  group('error diagnostics cite registry', () {
    test('arity error has the data name embedded', () {
      final env = _elab('data List[A: Type] : Type { nil : List[A]; }');
      try {
        infer(env.toCtx(), const TData('List', <Term>[]));
        fail('should have thrown');
      } on InductiveArityMismatch catch (e) {
        expect(e.dataName, 'List');
        expect(e.ctorName, isNull);
        expect(e.expectedArity, 1);
        expect(e.gotArity, 0);
      }
    });

    test('unknown ctor error identifies both data and ctor', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      try {
        infer(env.toCtx(), const TConstr('Nat', 'bogus', <Term>[]));
        fail('should have thrown');
      } on UnknownDataOrCtor catch (e) {
        expect(e.dataName, 'Nat');
        expect(e.ctorName, 'bogus');
      }
    });
  });
}
