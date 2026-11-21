/// Public kernel entry points: `elabProgram` elaborates, `checkProgram`
/// elaborates and audits.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/meta.dart';
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

const _nat = '''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''';

void main() {
  group('kernel entry points', () {
    test('checkProgram and elabProgram agree on a valid program', () {
      final program = _parse('''
$_nat
val id : (A: Type) -> A -> A = (A: Type) => (x: A) => x
''');
      final elaborated = elabProgram(program);
      final checked = checkProgram(program);
      expect(
        elaborated.bindings.map((b) => b.name).toList(),
        checked.bindings.map((b) => b.name).toList(),
      );
      expect(
        elaborated.dataDecls.map((d) => d.name).toList(),
        checked.dataDecls.map((d) => d.name).toList(),
      );
    });

    test('checkProgram runs the audit that elabProgram skips', () {
      // The source language cannot currently produce an ill-typed meta
      // solution (elaboration rejects the program first), so exercise the
      // difference at the boundary both entry points share: a DeclResult
      // whose solved meta is ill-typed. elabProgram would append such a
      // binding unchanged; checkProgram calls checkDeclResult, which
      // audits the solution and rejects it.
      final env = TopEnv.empty;
      final metas = MetaContext();
      final ctx = CNil.withRegistries(
        dataDecls: const <DataDecl>[],
        topBindings: const <String, TopBindingEntry>{},
        metas: metas,
      );
      const nat = VData('Nat', <Value>[]);
      final id = metas.freshTermMeta(nat, ctx);
      metas.solve(
        id,
        const TConstr('Eq', 'refl', [
          TData('Nat', []),
          TConstr('Nat', 'zero', []),
        ]),
      );
      final decl = (
        bindings: <TopBinding>[
          TopBinding(
            name: 'bad',
            type: const TData('Nat', []),
            term: TMeta(id),
            span: DoxaSpan.synthetic,
          ),
        ],
        dataDecls: const <DataDecl>[],
        corecursiveGroup: null,
        prescopeBindings: false,
        metas: metas,
        classRegistry: const <String, ClassInfo>{},
        namespaceBindings: const <String, Set<String>>{},
      );

      expect(
        () => checkDeclResult(env, decl),
        throwsA(isA<InvalidMetaSolution>()),
      );
    });
  });
}
