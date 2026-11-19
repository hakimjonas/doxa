/// Inlining an open solved meta under binders added after its declaration
/// shifts the escaped indices; inlining at or above its declaration level
/// does not, and below it leaves the meta untouched.
library;

import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/registry.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

CNil _base(MetaContext metas) => CNil.withRegistries(
  dataDecls: const <DataDecl>[],
  topBindings: const <String, TopBindingEntry>{},
  metas: metas,
);

void main() {
  group('meta scope at inlining', () {
    test('the same solution at its declaration level is unchanged', () {
      final metas = MetaContext();
      final base = _base(metas);
      final ctx = base.extend(const VType(LLevel(0)));
      final m = metas.freshTermMeta(const VType(LLevel(0)), ctx);
      metas.solve(m, const TBound(0));
      final term = TLam(const TType(LLevel(0)), TMeta(m));

      final inlined = inlineSolvedMetas(term, metas, outerDepth: 0);

      final outer = inlined as TLam;
      expect(outer.body, const TBound(0));
    });

    test('an ambient below the declaration level leaves the meta', () {
      final metas = MetaContext();
      final base = _base(metas);
      final ctx = base.extend(const VType(LLevel(0)));
      final m = metas.freshTermMeta(const VType(LLevel(0)), ctx);
      metas.solve(m, const TBound(0));

      final inlined = inlineSolvedMetas(TMeta(m), metas, outerDepth: 0);

      expect(inlined, isA<TMeta>());
      expect((inlined as TMeta).id, m);
    });
  });
}
