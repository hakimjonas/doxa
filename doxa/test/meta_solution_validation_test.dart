/// Solved metavariables are audited against their expected types.
///
/// `_Infer(TMeta)` returns a solved meta's pre-solve type instead of
/// re-typing the solution (solutions can contain quoted stuck forms that
/// are only well-typed under the expected type). `checkDeclResult` audits
/// every solution at the declaration boundary, so an ill-typed solution
/// is rejected rather than inlined into a stored declaration.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Prelude plus `Nat` and `plus`, elaborated exactly as `val`/`fun`
/// declarations would be.
TopEnv _natPlusEnv() {
  final prelude = loadPrelude();
  var env = TopEnv(
    prelude.bindings,
    prelude.dataDecls,
    const {},
    prelude.namespaceBindings,
  );
  final program =
      (parseProgram('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ k => succ (plus k n)
}
''')
              as Success<ParseError, SProgram>)
          .value;
  for (final decl in program.decls) {
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

/// A `DeclResult` for a single binding `name : type = term`.
DeclResult _decl(String name, Term type, Term body, MetaContext metas) => (
  bindings: <TopBinding>[
    TopBinding(name: name, type: type, term: body, span: DoxaSpan.synthetic),
  ],
  dataDecls: const <DataDecl>[],
  corecursiveGroup: null,
  metas: metas,
  classRegistry: const <String, ClassInfo>{},
  namespaceBindings: const <String, Set<String>>{},
);

void main() {
  group('solved metavariable validation', () {
    test('a solution of the wrong type is rejected by checkDeclResult', () {
      final env = _natPlusEnv();
      final metas = MetaContext();
      final ctx = CNil.withRegistries(
        dataDecls: env.dataDecls,
        topBindings: env.toCtx().env.topBindings,
        metas: metas,
      );
      // ?0 : Nat, solved with `refl Nat zero : Eq Nat zero zero`.
      const nat = VData('Nat', <Value>[]);
      final id = metas.freshTermMeta(nat, ctx);
      metas.solve(
        id,
        const TConstr('Eq', 'refl', [
          TData('Nat', []),
          TConstr('Nat', 'zero', []),
        ]),
      );

      expect(
        () => checkDeclResult(
          env,
          _decl('bad', const TData('Nat', []), TMeta(id), metas),
        ),
        throwsA(
          isA<InvalidMetaSolution>().having((e) => e.metaId, 'metaId', id),
        ),
      );
    });

    test('the old one-argument Eq.rec rewrite is rejected as a solution', () {
      // The tactic engine's pre-fix `rewrite` built
      // `Eq.rec A (λ b. G[x:=b]) x y p ?sub` with a one-argument motive.
      // Eq.rec's motive abstracts both indices and the proof, so the term
      // is ill-typed; it used to be accepted because the subgoal meta it
      // solved was trusted at its pre-solve type.
      final env = _natPlusEnv();
      final metas = MetaContext();
      final ctx = CNil.withRegistries(
        dataDecls: env.dataDecls,
        topBindings: env.toCtx().env.topBindings,
        metas: metas,
      );
      // G = Eq Nat (succ (plus zero zero)) (succ zero).
      final plusZero = eval(
        const TApp(
          TApp(TTop('plus'), TConstr('Nat', 'zero', [])),
          TConstr('Nat', 'zero', []),
        ),
        ctx.env,
      );
      final goal = VData('Eq', [
        const VData('Nat', <Value>[]),
        VConstr('Nat', 'succ', [plusZero]),
        const VConstr('Nat', 'succ', [VConstr('Nat', 'zero', <Value>[])]),
      ]);
      final id = metas.freshTermMeta(goal, ctx);

      const motive = TLam(
        TData('Nat', []),
        TData('Eq', [
          TData('Nat', []),
          TConstr('Nat', 'succ', [TBound(0)]),
          TConstr('Nat', 'succ', [TConstr('Nat', 'zero', [])]),
        ]),
      );
      const reflZero = TConstr('Eq', 'refl', [
        TData('Nat', []),
        TConstr('Nat', 'zero', []),
      ]);
      var oldRewrite = const TRec('Eq') as Term;
      for (final arg in <Term>[
        const TData('Nat', []),
        motive,
        const TApp(
          TApp(TTop('plus'), TConstr('Nat', 'zero', [])),
          TConstr('Nat', 'zero', []),
        ),
        const TConstr('Nat', 'zero', []),
        reflZero,
        reflZero,
      ]) {
        oldRewrite = TApp(oldRewrite, arg);
      }
      metas.solve(id, oldRewrite);

      expect(
        () => checkDeclResult(
          env,
          _decl('old_rewrite', quote(ctx.level, goal), TMeta(id), metas),
        ),
        throwsA(
          isA<InvalidMetaSolution>().having((e) => e.metaId, 'metaId', id),
        ),
      );
    });
  });
}
