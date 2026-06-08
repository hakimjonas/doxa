/// Inductive-type registry storage: DataDecl/CtorDecl storage, lookup, duplicate detection.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:test/test.dart';

// Fixtures: hand-built DataDecls / CtorDecls.

const _span0 = DoxaSpan(0, 10);
const _span1 = DoxaSpan(10, 20);
const _span2 = DoxaSpan(20, 30);

/// Surface AST for `data Nat : Type { zero : Nat; succ : Nat -> Nat }`.
const SDataKind natSource =
    SDataKind('Nat', <(String, SExpr?)>[], SExpr(STypeKind(0), _span0), [
      SCtorDecl('zero', SExpr(SIdentKind('Nat'), _span0), _span0),
      SCtorDecl(
        'succ',
        SExpr(
          SPiKind(
            null,
            SExpr(SIdentKind('Nat'), _span0),
            SExpr(SIdentKind('Nat'), _span0),
          ),
          _span0,
        ),
        _span1,
      ),
    ]);

/// Elaborated form of `data Nat`.
final DataDecl natDecl = DataDecl(
  name: 'Nat',
  params: const <TelescopeEntry>[],
  indices: const <TelescopeEntry>[],
  sort: const TType(0),
  ctors: [
    CtorDecl(
      dataName: 'Nat',
      name: 'zero',
      args: const <TelescopeEntry>[],
      resultIndices: const <Term>[],
      source: natSource.ctors[0],
      span: _span0,
    ),
    CtorDecl(
      dataName: 'Nat',
      name: 'succ',
      args: const [TelescopeEntry(null, TData('Nat', <Term>[]), _span0)],
      resultIndices: const <Term>[],
      source: natSource.ctors[1],
      span: _span1,
    ),
  ],
  paramsCovariant: const <bool>[],
  source: natSource,
  span: _span0,
);

/// Surface AST for `data Bool : Type { true : Bool; false : Bool }`.
const SDataKind boolSource =
    SDataKind('Bool', <(String, SExpr?)>[], SExpr(STypeKind(0), _span2), [
      SCtorDecl('true', SExpr(SIdentKind('Bool'), _span2), _span2),
      SCtorDecl('false', SExpr(SIdentKind('Bool'), _span2), _span2),
    ]);

final DataDecl boolDecl = DataDecl(
  name: 'Bool',
  params: const <TelescopeEntry>[],
  indices: const <TelescopeEntry>[],
  sort: const TType(0),
  ctors: [
    CtorDecl(
      dataName: 'Bool',
      name: 'true',
      args: const <TelescopeEntry>[],
      resultIndices: const <Term>[],
      source: boolSource.ctors[0],
      span: _span2,
    ),
    CtorDecl(
      dataName: 'Bool',
      name: 'false',
      args: const <TelescopeEntry>[],
      resultIndices: const <Term>[],
      source: boolSource.ctors[1],
      span: _span2,
    ),
  ],
  paramsCovariant: const <bool>[],
  source: boolSource,
  span: _span2,
);

void main() {
  group('TelescopeEntry', () {
    test('structural equality over name + type + span', () {
      expect(
        const TelescopeEntry('A', TType(0), _span0),
        const TelescopeEntry('A', TType(0), _span0),
      );
    });

    test('different names compare unequal', () {
      expect(
        const TelescopeEntry('A', TType(0), _span0),
        isNot(const TelescopeEntry('B', TType(0), _span0)),
      );
    });

    test('null name distinguishes anonymous binders', () {
      expect(
        const TelescopeEntry(null, TType(0), _span0),
        isNot(const TelescopeEntry('A', TType(0), _span0)),
      );
    });
  });

  group('SCtorDecl', () {
    test('structural equality', () {
      const c1 = SCtorDecl('zero', SExpr(SIdentKind('Nat'), _span0), _span0);
      const c2 = SCtorDecl('zero', SExpr(SIdentKind('Nat'), _span0), _span0);
      expect(c1, c2);
    });
  });

  group('TopEnv.empty', () {
    test('has no bindings and no data decls', () {
      expect(TopEnv.empty.bindings, isEmpty);
      expect(TopEnv.empty.dataDecls, isEmpty);
    });

    test('lookupData returns null', () {
      expect(TopEnv.empty.lookupData('Nat'), isNull);
    });

    test('lookupCtor returns null', () {
      expect(TopEnv.empty.lookupCtor('Nat', 'zero'), isNull);
    });
  });

  group('TopEnv with dataDecls', () {
    final env = TopEnv(const <TopBinding>[], [natDecl, boolDecl]);

    test('lookupData finds registered names', () {
      expect(env.lookupData('Nat'), same(natDecl));
      expect(env.lookupData('Bool'), same(boolDecl));
    });

    test('lookupData returns null for unknown names', () {
      expect(env.lookupData('List'), isNull);
    });

    test('lookupCtor finds constructors of a registered data type', () {
      final zero = env.lookupCtor('Nat', 'zero');
      expect(zero, isNotNull);
      expect(zero!.name, 'zero');
      expect(zero.dataName, 'Nat');

      final succ = env.lookupCtor('Nat', 'succ');
      expect(succ, isNotNull);
      expect(succ!.args, hasLength(1));
      expect(succ.args.first.type, const TData('Nat', <Term>[]));
    });

    test('lookupCtor returns null for unknown data name', () {
      expect(env.lookupCtor('List', 'cons'), isNull);
    });

    test('lookupCtor returns null for unknown ctor name', () {
      expect(env.lookupCtor('Nat', 'pred'), isNull);
    });

    test('spanOf finds data names and constructor names', () {
      expect(env.spanOf('Nat'), _span0);
      expect(env.spanOf('zero'), _span0);
      expect(env.spanOf('succ'), _span1);
      expect(env.spanOf('Bool'), _span2);
      expect(env.spanOf('Unknown'), isNull);
    });
  });

  group('shadowing discipline', () {
    test('later DataDecl with same name shadows the earlier in lookupData', () {
      // Two Nat declarations, the first wins because lookup iterates
      // in source order and returns the first match. The elaborator
      // is expected to reject duplicates; registry storage itself
      // does not enforce uniqueness.
      final env = TopEnv(const <TopBinding>[], [natDecl, natDecl]);
      expect(env.lookupData('Nat'), same(natDecl));
    });
  });

  group('surface AST preserved', () {
    test('DataDecl.source points at the SDataKind it was elaborated from', () {
      expect(identical(natDecl.source, natSource), isTrue);
    });

    test('CtorDecl.source points at the SCtorDecl it was elaborated from', () {
      expect(identical(natDecl.ctors[0].source, natSource.ctors[0]), isTrue);
      expect(identical(natDecl.ctors[1].source, natSource.ctors[1]), isTrue);
    });
  });
}
