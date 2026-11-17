/// `revert x` moves the innermost local binder back into the goal.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/tactic.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate and kernel-check [src] the way the CLI does.
TopEnv _elabAndCheck(String src) {
  final prelude = loadPrelude();
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  for (final decl in _parse(src).decls) {
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

TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

const _nat = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''';

/// A context [n: Nat, h: Eq Nat n n] (h innermost) with the goal
/// `Eq Nat n n`, for direct tactic tests.
(TacticState, MetaContext) _twoBinderState() {
  final env = _elabAndCheck(_nat);
  final metas = MetaContext();
  final base = env.toCtx(metas: metas);
  const nat = VData('Nat', <Value>[]);
  final n = VNeutral(NVar(base.level));
  final ctx1 = base.extend(nat);
  final hType = VData('Eq', [nat, n, n]);
  final ctx2 = ctx1.extend(hType);
  const goal = VData('Eq', [nat, VNeutral(NVar(1)), VNeutral(NVar(1))]);
  final id = metas.freshTermMeta(goal, ctx2);
  return (TacticState(metas, ctx2, id, const ['h', 'n']), metas);
}

void main() {
  group('revert', () {
    test('id_revert round-trips through the tactic and checks', () {
      final env = _elabAndCheck('''
val id_revert : (A: Type) -> (x: A) -> Eq A x x = by {
  intro A;
  intro x;
  revert x;
  intro x;
  refl
}
''');
      expect(_binding(env, 'id_revert').name, 'id_revert');
    });

    test('reverting the innermost binder produces a closed Pi goal', () {
      final (state, _) = _twoBinderState();
      final result = revert('h')(state);
      expect(result, isA<TacticOk>());
      final goal = (result as TacticOk).subGoals.single;
      expect(goal.closedOverCtx, isNotNull);
      final display = goal.displayType;
      expect(display, isA<VPi>());
      expect((display! as VPi).domain, isA<VData>());
      expect(goal.binderNames, const ['n']);
    });

    test('a binder with dependents inside it fails with a diagnostic', () {
      final (state, _) = _twoBinderState();
      final result = revert('n')(state);
      expect(result, isA<TacticFail>());
      expect(
        (result as TacticFail).message,
        contains('not the innermost binder'),
      );
    });

    test('an unknown binder fails', () {
      final (state, _) = _twoBinderState();
      final result = revert('missing')(state);
      expect(result, isA<TacticFail>());
      expect((result as TacticFail).message, contains('not in scope'));
    });
  });
}
