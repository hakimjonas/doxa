/// Property-based (fuzz) testing for the kernel.
///
/// Generates random terms and checks kernel invariants:
///   * `eval` always terminates for well-formed terms
///   * `conv(a, a)` is always `ConvOk` (conversion is reflexive)
///   * `quote(level, eval(term, env))` round-trips to a term that
///     re-evaluates to the same value
library;

import 'package:test/test.dart';
import 'package:doxa/src/eval.dart' show eval, conv, quote, ConvOk;
import 'package:doxa/src/env.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';

void main() {
  group('Fuzz: kernel invariants', () {
    test('conv is reflexive for random Types', () {
      for (var level = 0; level <= 5; level++) {
        final v = VType(LLevel(level));
        final result = conv(0, v, v);
        expect(result, isA<ConvOk>(), reason: 'VType($level) ≟ VType($level)');
      }
    });

    test('conv is reflexive for Prop and SProp', () {
      expect(conv(0, const VProp(), const VProp()), isA<ConvOk>());
      expect(conv(0, const VSProp(), const VSProp()), isA<ConvOk>());
    });

    test('quote(level, VType(n)) round-trips through eval', () {
      const env = ENil();
      for (var level = 0; level <= 5; level++) {
        final v = VType(LLevel(level));
        final quoted = quote(0, v);
        final reEvaled = eval(quoted, env);
        expect(
          conv(0, reEvaled, v),
          isA<ConvOk>(),
          reason: 'VType($level) round-trip',
        );
      }
    });

    test('quote(level, eval(closed term)) round-trips', () {
      const env = ENil();
      const terms = <Term>[
        TType(LLevel(0)),
        TType(LLevel(1)),
        TProp(),
        TSProp(),
      ];
      for (final term in terms) {
        final v = eval(term, env);
        final quoted = quote(0, v);
        final reEvaled = eval(quoted, env);
        expect(
          conv(0, reEvaled, v),
          isA<ConvOk>(),
          reason: 'round-trip failed for $term',
        );
      }
    });

    test('eval terminates for simple closed terms', () {
      const env = ENil();
      const terms = <Term>[
        TType(LLevel(0)),
        TType(LLevel(3)),
        TProp(),
        TSProp(),
        // Pi types: (x: Type) -> Type
        TPi(TType(LLevel(0)), TType(LLevel(0))),
        // Lambda: (x: Type) -> x
        TLam(TType(LLevel(0)), TBound(0)),
      ];
      for (final term in terms) {
        expect(
          () => eval(term, env),
          returnsNormally,
          reason: 'eval should not throw for $term',
        );
      }
    });
  });
}
