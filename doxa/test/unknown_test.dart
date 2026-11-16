/// `TUnknown` / `VUnknown`: the internal unknown marker.
///
/// The marker replaces the old `TType(0)` / `VType(0)` sentinel used by
/// the mutual pre-bindings and the expression shim. These tests pin the
/// kernel-level contract: it converts only with itself, it never solves
/// a metavariable, and inferring a term whose type is unknown is an
/// internal error rather than a guess.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

void main() {
  group('Term and value forms', () {
    test('TUnknown equality and display', () {
      expect(const TUnknown(), const TUnknown());
      expect(const TUnknown().hashCode, const TUnknown().hashCode);
      expect(const TUnknown().toString(), 'TUnknown');
      expect(prettyTerm(const TUnknown()), 'Unknown');
    });

    test('TUnknown is distinct from every real sort', () {
      expect(const TUnknown(), isNot(const TType(LLevel(0))));
      expect(const TUnknown(), isNot(const TProp()));
      expect(const TUnknown(), isNot(const TSProp()));
    });

    test('eval(TUnknown) yields VUnknown', () {
      expect(eval(const TUnknown(), const ENil()), isA<VUnknown>());
    });

    test('quote(VUnknown) yields TUnknown', () {
      expect(quote(0, const VUnknown()), const TUnknown());
    });

    test('open and close leave TUnknown alone', () {
      expect(openTerm(const TUnknown(), 'x'), const TUnknown());
      expect(closeTerm(const TUnknown(), 'x'), const TUnknown());
    });
  });

  group('Conversion admits the unknown only against itself', () {
    test('VUnknown converts with VUnknown', () {
      expect(conv(0, const VUnknown(), const VUnknown()), isA<ConvOk>());
    });

    test('VUnknown does not convert with any Type level', () {
      for (final level in const [0, 1, 3]) {
        final t = VType(LLevel(level));
        expect(
          conv(0, const VUnknown(), t),
          isA<ConvMismatch>(),
          reason: 'VUnknown vs Type $level',
        );
        expect(
          conv(0, t, const VUnknown()),
          isA<ConvMismatch>(),
          reason: 'Type $level vs VUnknown',
        );
      }
    });

    test('VUnknown does not convert with Prop or SProp', () {
      expect(conv(0, const VUnknown(), const VProp()), isA<ConvMismatch>());
      expect(conv(0, const VProp(), const VUnknown()), isA<ConvMismatch>());
      expect(conv(0, const VUnknown(), const VSProp()), isA<ConvMismatch>());
      expect(conv(0, const VSProp(), const VUnknown()), isA<ConvMismatch>());
    });

    test('VUnknown does not convert with a Pi, data type, or neutral', () {
      final pi = eval(
        const TPi(TType(LLevel(0)), TType(LLevel(0))),
        const ENil(),
      );
      expect(conv(0, const VUnknown(), pi), isA<ConvMismatch>());
      expect(conv(0, pi, const VUnknown()), isA<ConvMismatch>());

      const data = VData('Nat', []);
      expect(conv(0, const VUnknown(), data), isA<ConvMismatch>());
      expect(conv(0, data, const VUnknown()), isA<ConvMismatch>());

      const neutral = VNeutral(NVar(0));
      expect(conv(0, const VUnknown(), neutral), isA<ConvMismatch>());
      expect(conv(0, neutral, const VUnknown()), isA<ConvMismatch>());
    });

    test('subtype admits the unknown only against itself', () {
      expect(subtype(0, const VUnknown(), const VUnknown()), isA<ConvOk>());
      expect(
        subtype(0, const VUnknown(), const VType(LLevel(0))),
        isA<ConvMismatch>(),
      );
      expect(
        subtype(0, const VType(LLevel(0)), const VUnknown()),
        isA<ConvMismatch>(),
      );
    });

    test('VUnknown never solves a metavariable', () {
      final metas = MetaContext();
      final id = metas.freshTermMeta(const VType(LLevel(1)), const CNil());
      final metaValue = eval(TMeta(id), const ENil());
      final r = conv(0, const VUnknown(), metaValue, metas: metas);
      expect(r, isA<ConvMismatch>());
      expect(
        metas.isSolved(id),
        isFalse,
        reason: 'the unknown marker must not stand in for a guessed type',
      );
    });
  });

  group('The unknown never types a term', () {
    test('infer(TUnknown) is an internal error', () {
      expect(
        () => infer(const CNil(), const TUnknown()),
        throwsA(isA<UnknownTypeReached>()),
      );
    });

    test('check(TUnknown, real type) is an internal error', () {
      expect(
        () => check(const CNil(), const TUnknown(), const VType(LLevel(0))),
        throwsA(isA<UnknownTypeReached>()),
      );
    });

    test('checking a real term against VUnknown is rejected', () {
      // `Type` has type `Type 1`; the unknown is not a supertype of
      // anything real.
      expect(
        () => check(const CNil(), const TType(LLevel(0)), const VUnknown()),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('applying VUnknown is a kernel invariant violation', () {
      expect(
        () => conv(
          0,
          eval(const TApp(TUnknown(), TUnknown()), const ENil()),
          const VUnknown(),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
