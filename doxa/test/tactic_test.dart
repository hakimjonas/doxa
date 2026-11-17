/// Tests for tactics (`by { ... }` blocks) and theorem declarations.
library;

import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/tactic.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

final PreludeData prelude = loadPrelude();

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate [src] starting from the prelude's bindings + dataDecls.
TopEnv _elab(String src) {
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  final prog = _parse(src);
  for (final decl in prog.decls) {
    final produced = elabDecl(env, decl);
    env = TopEnv(
      [...env.bindings, ...produced.bindings],
      [...env.dataDecls, ...produced.dataDecls],
      {...env.classRegistry, ...produced.classRegistry},
      mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
    );
  }
  return env;
}

/// Elaborate and declaration-check [src] the way the CLI does, starting
/// from the prelude, so tactic-built terms are kernel-checked.
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

/// The `Nat` and `plus` prelude used by the sequencing tests.
const _natPlus = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}
''';

void main() {
  group('theorem parsing', () {
    test('theorem with by block parses', () {
      final r = parseProgram('theorem t : Type := by { refl }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('theorem desugars to SValKind', () {
      final prog = _parse('theorem t : Type := by { refl }');
      expect(prog.decls[0].kind, isA<SValKind>());
      final val = prog.decls[0].kind as SValKind;
      expect(val.name, 't');
      expect(val.type, isNotNull);
    });

    test('theorem with = works (no :=)', () {
      final r = parseProgram('theorem t : Type = Type');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('theorem with := works', () {
      final r = parseProgram('theorem t : Type := Type');
      expect(r, isA<Success<ParseError, SProgram>>());
    });
  });

  group('by block parsing', () {
    test('by { refl } parses', () {
      final r = parseProgram('val x : Type = by { refl }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('by { intro x; exact x } parses', () {
      final r = parseProgram('val x : Type = by { intro x; exact x }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });

    test('by { refl | trivial } parses (alternatives)', () {
      final r = parseProgram('val x : Type = by { refl | trivial }');
      expect(r, isA<Success<ParseError, SProgram>>());
    });
  });

  group('tactic elaboration', () {
    test('intro and exact prove (A: Type) -> A -> A', () {
      final prog = _parse('''
val id : (A: Type) -> A -> A = by { intro A; intro x; exact x }
''');
      final env = elabProgram(prog);
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'id'),
        returnsNormally,
      );
    });

    test('by block in infer mode fails', () {
      expect(() => _elab('val x = by { refl }'), throwsA(isA<TacticFailed>()));
    });

    test('rewrite using an equality', () {
      // Simpler: just rewrite.  The rewrite should leave a subgoal
      // of the same type (since x = x).  Needs prelude for Eq.
      final env = _elab('''
val rewrite_test : (A: Type) -> (x: A) -> (h: Eq A x x) -> Eq A x x =
  (A: Type) => (x: A) => (h: Eq A x x) => by { rewrite h; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'rewrite_test'),
        returnsNormally,
      );
    });

    test('rewrite identity test with trivial', () {
      final env = _elab('''
val rewrite_trivial : (A: Type) -> (x: A) -> (h: Eq A x x) -> Eq A x x =
  (A: Type) => (x: A) => (h: Eq A x x) => by { rewrite h | trivial; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'rewrite_trivial'),
        returnsNormally,
      );
    });

    test('induction on Eq using refl', () {
      // Prove: (A: Type) -> (x: A) -> (y: A) -> (h: Eq A x y) -> Eq A x y
      // by induction on h, then exact h (refl case).
      final env = _elab('''
val induction_eq : (A: Type) -> (x: A) -> (y: A) -> (h: Eq A x y) -> Eq A x y =
  (A: Type) => (x: A) => (y: A) => (h: Eq A x y) => by { induction h; exact h }
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'induction_eq'),
        returnsNormally,
      );
    });

    test('induction creates subgoals and solves them', () {
      // Simple single-constructor type to avoid multi-subgoal sequencing.
      final env = _elab('''
data Wrap : Prop { wrap : Wrap; }
val induction_wrap : (w: Wrap) -> Wrap = (w: Wrap) => by {
  induction w; exact wrap
}
''');
      expect(
        () => env.bindings.firstWhere((b) => b.name == 'induction_wrap'),
        returnsNormally,
      );
    });
  });

  group('induction goal refinement', () {
    /// Open [typeSrc] at a fresh binder and return the extended context
    /// plus the goal type under that binder.
    (Ctx, Value) openPi(TopEnv env, MetaContext metas, String typeSrc) {
      final parsed = parseExpr(typeSrc);
      if (parsed is! Success<ParseError, SExpr>) {
        fail('parse failed: $parsed');
      }
      final typeTerm = elabExpr(env, parsed.value);
      final baseCtx = env.toCtx(metas: metas);
      final pi = eval(typeTerm, baseCtx.env) as VPi;
      final ctx = baseCtx.extend(pi.domain);
      final goal = eval(
        pi.codomain.body,
        pi.codomain.env.extend(VNeutral(NVar(ctx.level - 1))),
      );
      return (ctx, goal);
    }

    test('the zero arm of a Nat induction mentions the reduced '
        'application, not the stuck one', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}
''');
      final metas = MetaContext();
      final (ctx, goal) = openPi(
        env,
        metas,
        '(n: Nat) -> Eq Nat (plus n zero) (plus n zero)',
      );
      final goalId = metas.freshTermMeta(goal, ctx);
      final state = TacticState(metas, ctx, goalId, const ['n']);

      final result = induction('n')(state);
      expect(result, isA<TacticOk>());
      final zeroMeta = (result as TacticOk).subMeta!;
      final zeroGoal =
          (metas.lookup(zeroMeta) as TermMetaUnsolved).typeExpected;

      // Before the fix this printed `Eq Nat (plus zero zero)
      // (plus zero zero)`: the substituted application stayed a frozen
      // VFun. Refinement must expose the reduced form so subsequent
      // tactics (and the final kernel check) see `Eq Nat zero zero`.
      expect(prettyTerm(quote(ctx.level, zeroGoal)), 'Eq Nat zero zero');
    });

    test('a goal without a top-level function refines as before', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final metas = MetaContext();
      final (ctx, goal) = openPi(env, metas, '(n: Nat) -> Eq Nat n n');
      final goalId = metas.freshTermMeta(goal, ctx);
      final state = TacticState(metas, ctx, goalId, const ['n']);

      final result = induction('n')(state);
      expect(result, isA<TacticOk>());
      final zeroMeta = (result as TacticOk).subMeta!;
      final zeroGoal =
          (metas.lookup(zeroMeta) as TermMetaUnsolved).typeExpected;

      expect(prettyTerm(quote(ctx.level, zeroGoal)), 'Eq Nat zero zero');
    });
  });

  group('multi-goal sequencing', () {
    test('induction arms are consumed in order and the IH is usable', () {
      final env = _elabAndCheck('''
$_natPlus
val plus_zero : (n: Nat) -> Eq Nat (plus n zero) n = (n: Nat) => by {
  induction n;
  refl;
  rewrite ih;
  refl
}
''');
      expect(env.bindings.where((b) => b.name == 'plus_zero'), hasLength(1));
    });

    test('a reflexivity goal closes with one refl per arm', () {
      final env = _elabAndCheck('''
$_natPlus
val plus_refl : (n: Nat) -> Eq Nat (plus n zero) (plus n zero) =
  (n: Nat) => by {
    induction n;
    refl;
    refl
  }
''');
      expect(env.bindings.where((b) => b.name == 'plus_refl'), hasLength(1));
    });

    test('an induction arm left unsolved fails the block', () {
      expect(
        () => _elabAndCheck('''
$_natPlus
val plus_incomplete : (n: Nat) -> Eq Nat (plus n zero) (plus n zero) =
  (n: Nat) => by {
    induction n;
    refl
  }
'''),
        throwsA(isA<TacticFailed>()),
      );
    });
  });
}
