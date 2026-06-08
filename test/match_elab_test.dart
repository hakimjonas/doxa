/// Elaboration, coverage, and check tests for `match`.
library;

import 'package:doxa/src/check.dart'
    show MatchMotiveRequired, ScrutineeTypeMismatchesArm, TypeMismatch;
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart' show check, eval;
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Full CLI-style check: elaborate and check each declaration through
/// the same `elabDecl` + `checkDeclResult` path the CLI uses, so solved
/// metavariables are inlined into the finalized terms before checking
/// (a raw `elabProgram` + `check` would leave `TMeta` nodes that a
/// metas-free `check` ctx rejects).
void _elabAndCheck(String src) {
  final prog = _parse(src);
  var bindings = const <TopBinding>[];
  var dataDecls = const <DataDecl>[];
  for (final decl in prog.decls) {
    final env = TopEnv(bindings, dataDecls);
    final produced = elabDecl(env, decl);
    final runningData = [...dataDecls, ...produced.dataDecls];
    final runningEnv = TopEnv(bindings, runningData);
    final finalized = checkDeclResult(runningEnv, produced);
    bindings = [...bindings, ...finalized];
    dataDecls = runningData;
  }
}

void main() {
  group('well-formed matches elaborate + check', () {
    test('Nat pred via match', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ m => m
}

val two : Nat = succ (succ zero)
val one : Nat = pred two
''');
    });

    test('Nat pred with explicit matching motive', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun pred(n: Nat): Nat = match n returning Nat {
  case zero => zero
  case succ m => m
}
''');
    });

    test('parametric List head-or-default', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

fun headOr(def: Nat, xs: List[Nat]): Nat = match xs {
  case nil => def
  case cons x rest => x
}

val xs : List[Nat] = cons (succ zero) nil
val n  : Nat       = headOr zero xs
''');
    });

    test('wildcard covers remaining ctors', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun isZero(n: Nat): Nat = match n {
  case zero => succ zero
  case _ => zero
}
''');
    });

    test('wildcard-only match with explicit motive', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun always(n: Nat): Nat = match n returning Nat {
  case _ => zero
}
''');
    });

    test('underscore binder in ctor pattern', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun oneIfSucc(n: Nat): Nat = match n {
  case zero => zero
  case succ _ => succ zero
}
''');
    });

    test('infer-mode match with explicit motive', () {
      _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val x = match zero returning Nat {
  case zero => zero
  case succ m => m
}
''');
    });

    test('two-constructor Bool match', () {
      _elabAndCheck('''
data Bool : Type {
  true_  : Bool;
  false_ : Bool;
}

fun not_(b: Bool): Bool = match b {
  case true_  => false_
  case false_ => true_
}
''');
    });
  });

  group('motive discipline: honesty required', () {
    test('`returning Bool` on a Nat-typed match is REJECTED', () {
      // Soundness: an explicit motive that disagrees with the expected
      // type must not be silently ignored.
      expect(
        () => _elabAndCheck('''
data Nat  : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

val x : Nat = match zero returning Bool {
  case zero => zero
  case succ m => m
}
'''),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('explicit motive that matches expected type is accepted', () {
      _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val x : Nat = match zero returning Nat {
  case zero => zero
  case succ m => m
}
''');
    });

    test('implicit motive uses expected type (constant motive)', () {
      _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val x : Nat = match zero {
  case zero => zero
  case succ m => m
}
''');
    });

    test('infer-mode match without motive → MatchMotiveRequired', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val x = match zero {
  case zero => zero
  case succ m => m
}
'''),
        throwsA(isA<MatchMotiveRequired>()),
      );
    });
  });

  group('coverage errors', () {
    test('missing constructor → NonExhaustiveMatch', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun bad(n: Nat): Nat = match n {
  case zero => zero
}
'''),
        throwsA(
          isA<NonExhaustiveMatch>()
              .having((e) => e.dataName, 'dataName', 'Nat')
              .having((e) => e.missingCtors, 'missingCtors', ['succ']),
        ),
      );
    });

    test('two-ctor type, one missing, reports the missing one', () {
      expect(
        () => _elabAndCheck('''
data Bool : Type { true_ : Bool; false_ : Bool; }

fun bad(b: Bool): Bool = match b {
  case true_ => false_
}
'''),
        throwsA(
          isA<NonExhaustiveMatch>().having(
            (e) => e.missingCtors,
            'missingCtors',
            ['false_'],
          ),
        ),
      );
    });

    test('unknown ctor name → UnknownCtorInMatch', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun bad(n: Nat): Nat = match n {
  case nil => zero
  case cons x y => zero
}
'''),
        throwsA(
          isA<UnknownCtorInMatch>().having(
            (e) => e.ctorName,
            'ctorName',
            'nil',
          ),
        ),
      );
    });

    test('ctor from wrong inductive type → CtorMismatchInMatch', () {
      // The scrutinee's type is known here; an arm names a ctor from a
      // different inductive (distinct from the all-arms-agree case below).
      expect(
        () => _elabAndCheck('''
data Nat  : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

fun bad(n: Nat): Nat = match n {
  case zero => zero
  case true_ => zero
}
'''),
        throwsA(
          isA<CtorMismatchInMatch>()
              .having((e) => e.ctorName, 'ctorName', 'true_')
              .having((e) => e.ctorDataName, 'ctorDataName', 'Bool')
              .having((e) => e.scrutineeDataName, 'scrutineeDataName', 'Nat'),
        ),
      );
    });

    test(
      'scrutinee-type disagrees with ctors → ScrutineeTypeMismatchesArm',
      () {
        // Every arm's ctor resolves to Bool, so elab infers a Bool
        // match, but the scrutinee is actually Nat. Caught at check
        // time with an error that points at the offending arm.
        expect(
          () => _elabAndCheck('''
data Nat  : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

fun bad(n: Nat): Nat = match n {
  case true_ => zero
  case false_ => zero
}
'''),
          throwsA(
            isA<ScrutineeTypeMismatchesArm>()
                .having((e) => e.armCtorName, 'armCtorName', 'true_')
                .having((e) => e.armCtorDataName, 'armCtorDataName', 'Bool')
                .having((e) => e.scrutineeDataName, 'scrutineeDataName', 'Nat')
                .having((e) => e.armSpan, 'armSpan', isNotNull),
          ),
        );
      },
    );

    test(
      'arm span on ScrutineeTypeMismatchesArm points at the arm, not the decl',
      () {
        // The error must carry the arm's span (which the CLI prefers
        // over the decl span). Regression: this diagnostic once pointed
        // at the `val x` line instead of the offending `case`.
        const src = '''
data Nat  : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

fun bad(n: Nat): Nat = match n {
  case true_ => zero
  case false_ => zero
}
''';
        try {
          _elabAndCheck(src);
          fail('expected ScrutineeTypeMismatchesArm');
        } on ScrutineeTypeMismatchesArm catch (e) {
          expect(e.armSpan, isNotNull);
          // The arm's span should start at the `case true_` region,
          // not the `fun bad` region.
          final caseTrueStart = src.indexOf('case true_');
          final funBadStart = src.indexOf('fun bad');
          expect(e.armSpan!.start, greaterThanOrEqualTo(caseTrueStart));
          expect(e.armSpan!.start, greaterThan(funBadStart));
        }
      },
    );

    test('duplicate ctor case → DuplicateMatchCase', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun bad(n: Nat): Nat = match n {
  case zero => zero
  case zero => zero
  case succ m => m
}
'''),
        throwsA(
          isA<DuplicateMatchCase>().having(
            (e) => e.ctorName,
            'ctorName',
            'zero',
          ),
        ),
      );
    });

    test('ctor arity too few → MatchArmArityMismatch', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun bad(n: Nat): Nat = match n {
  case zero => zero
  case succ => zero
}
'''),
        throwsA(
          isA<MatchArmArityMismatch>()
              .having((e) => e.ctorName, 'ctorName', 'succ')
              .having((e) => e.gotBinders, 'gotBinders', 0)
              .having((e) => e.expectedBinders, 'expectedBinders', 1),
        ),
      );
    });

    test('ctor arity too many → MatchArmArityMismatch', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun bad(n: Nat): Nat = match n {
  case zero => zero
  case succ x y => x
}
'''),
        throwsA(
          isA<MatchArmArityMismatch>()
              .having((e) => e.gotBinders, 'gotBinders', 2)
              .having((e) => e.expectedBinders, 'expectedBinders', 1),
        ),
      );
    });

    test('wildcard-only match with no motive → MatchIndeterminateType', () {
      expect(
        () => _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val x : Nat = match zero {
  case _ => zero
}
'''),
        throwsA(isA<MatchIndeterminateType>()),
      );
    });
  });

  group('arm body type checks', () {
    test('arm body returning wrong type → TypeMismatch', () {
      expect(
        () => _elabAndCheck('''
data Nat  : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

val x : Nat = match zero {
  case zero => true_
  case succ m => m
}
'''),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('arm binder is in scope in the body', () {
      _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ p => p
}
''');
    });

    test('arm body sees binder with correct type (ctor arg type)', () {
      // No explicit type assertion: if the binder's type weren't
      // propagated, using it as a Nat (succ p) would fail the check.
      _elabAndCheck('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun doublePred(n: Nat): Nat = match n {
  case zero => zero
  case succ p => succ p
}
''');
    });
  });

  group('end-to-end reduction through match', () {
    test('pred (succ (succ zero)) normalizes to succ zero', () {
      final env = elabProgram(
        _parse('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ m => m
}

val two : Nat = succ (succ zero)
val one : Nat = pred two
'''),
      );
      final acc = <TopBinding>[];
      for (final b in env.bindings) {
        final ctx = TopEnv(acc, env.dataDecls).toCtx();
        check(ctx, b.term, eval(b.type, ctx.env));
        acc.add(b);
      }
      // Evaluate `one` in a ctx seeded by prior bindings (mirrors the
      // CLI's per-binding evaluation).
      final oneIdx = env.bindings.indexWhere((b) => b.name == 'one');
      final priorEnv = TopEnv(env.bindings.sublist(0, oneIdx), env.dataDecls);
      final ctx = priorEnv.toCtx();
      final v = eval(env.bindings[oneIdx].term, ctx.env);
      expect(v, isA<VConstr>());
      final c = v as VConstr;
      expect(c.ctorName, 'succ');
      expect((c.args.single as VConstr).ctorName, 'zero');
    });
  });
}
