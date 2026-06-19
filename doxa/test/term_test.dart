import 'package:doxa/src/term.dart';
import 'package:test/test.dart';

void main() {
  group('Term equality', () {
    test('same shape compares equal', () {
      expect(const TType(LLevel(0)), const TType(LLevel(0)));
      expect(const TBound(2), const TBound(2));
      expect(const TFree('x'), const TFree('x'));
      expect(
        const TApp(TFree('f'), TBound(0)),
        const TApp(TFree('f'), TBound(0)),
      );
      expect(
        const TLam(TType(LLevel(0)), TBound(0)),
        const TLam(TType(LLevel(0)), TBound(0)),
      );
      expect(
        const TPi(TType(LLevel(0)), TBound(0)),
        const TPi(TType(LLevel(0)), TBound(0)),
      );
    });

    test('different shape compares unequal', () {
      expect(const TType(LLevel(0)), isNot(const TType(LLevel(1))));
      expect(const TBound(0), isNot(const TBound(1)));
      expect(const TFree('x'), isNot(const TFree('y')));
      expect(
        const TLam(TType(LLevel(0)), TBound(0)),
        isNot(const TPi(TType(LLevel(0)), TBound(0))),
      );
    });
  });

  group('openTerm', () {
    test('leaf types unchanged', () {
      expect(openTerm(const TType(LLevel(0)), 'x'), const TType(LLevel(0)));
      expect(openTerm(const TFree('y'), 'x'), const TFree('y'));
    });

    test('TBound(0) at top level becomes TFree', () {
      expect(openTerm(const TBound(0), 'x'), const TFree('x'));
    });

    test('TBound(i > 0) at top level decrements', () {
      expect(openTerm(const TBound(1), 'x'), const TBound(0));
      expect(openTerm(const TBound(3), 'x'), const TBound(2));
    });

    test('under one TLam, TBound(1) becomes TFree(x)', () {
      const input = TLam(TType(LLevel(0)), TBound(1));
      const expected = TLam(TType(LLevel(0)), TFree('x'));
      expect(openTerm(input, 'x'), expected);
    });

    test('under one TLam, TBound(0) stays bound', () {
      const input = TLam(TType(LLevel(0)), TBound(0));
      expect(openTerm(input, 'x'), input);
    });

    test('under nested TLam, TBound(2) becomes TFree(x)', () {
      // λ. λ. TBound(2), references the binder being opened.
      const input = TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TBound(2)));
      const expected = TLam(
        TType(LLevel(0)),
        TLam(TType(LLevel(0)), TFree('x')),
      );
      expect(openTerm(input, 'x'), expected);
    });

    test('under nested TLam, TBound(3) decrements to TBound(2)', () {
      // An even deeper outer reference should drop by one level.
      const input = TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TBound(3)));
      const expected = TLam(
        TType(LLevel(0)),
        TLam(TType(LLevel(0)), TBound(2)),
      );
      expect(openTerm(input, 'x'), expected);
    });

    test('TPi walks domain at current depth, codomain at depth+1', () {
      // TPi(TBound(0), TBound(0)) at the top level:
      //   domain TBound(0) refers to the binder being opened → TFree(x)
      //   codomain TBound(0) refers to the Pi's own binder → stays bound
      const input = TPi(TBound(0), TBound(0));
      const expected = TPi(TFree('x'), TBound(0));
      expect(openTerm(input, 'x'), expected);
    });

    test('TApp walks both children at the same depth', () {
      const input = TApp(TBound(0), TBound(0));
      const expected = TApp(TFree('x'), TFree('x'));
      expect(openTerm(input, 'x'), expected);
    });
  });

  group('closeTerm', () {
    test('leaf types unchanged when name not present', () {
      expect(closeTerm(const TType(LLevel(0)), 'x'), const TType(LLevel(0)));
      expect(closeTerm(const TFree('y'), 'x'), const TFree('y'));
    });

    test('TFree(x) at top level becomes TBound(0)', () {
      expect(closeTerm(const TFree('x'), 'x'), const TBound(0));
    });

    test('TBound(i >= 0) at top level increments', () {
      expect(closeTerm(const TBound(0), 'x'), const TBound(1));
      expect(closeTerm(const TBound(2), 'x'), const TBound(3));
    });

    test('under one TLam, TFree(x) becomes TBound(1)', () {
      const input = TLam(TType(LLevel(0)), TFree('x'));
      const expected = TLam(TType(LLevel(0)), TBound(1));
      expect(closeTerm(input, 'x'), expected);
    });

    test('under one TLam, TBound(0) stays bound (< depth)', () {
      const input = TLam(TType(LLevel(0)), TBound(0));
      expect(closeTerm(input, 'x'), input);
    });

    test('under nested TLam, TFree(x) becomes TBound(2)', () {
      const input = TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TFree('x')));
      const expected = TLam(
        TType(LLevel(0)),
        TLam(TType(LLevel(0)), TBound(2)),
      );
      expect(closeTerm(input, 'x'), expected);
    });

    test('TPi: closes TFree in codomain under binder, shifts in domain', () {
      // TPi(TFree(x), TFree(x)), x in domain becomes TBound(0),
      // x in codomain (under one binder) becomes TBound(1).
      const input = TPi(TFree('x'), TFree('x'));
      const expected = TPi(TBound(0), TBound(1));
      expect(closeTerm(input, 'x'), expected);
    });

    test('different free variable name unaffected', () {
      const input = TLam(TType(LLevel(0)), TFree('y'));
      expect(closeTerm(input, 'x'), input);
    });
  });

  group('Round-trip: close(open(t, x), x) == t when x fresh', () {
    // A variety of hand-constructed terms where "x" does not appear free.
    final cases = <Term>[
      // Leaf: dangling TBound(0) alone.
      const TBound(0),
      // Deeper dangling indices.
      const TBound(3),
      // Lambda with a reference to the opened binder.
      const TLam(TType(LLevel(0)), TBound(1)),
      // Lambda with an inner-bound reference (TBound(0) inside).
      const TLam(TType(LLevel(0)), TBound(0)),
      // Nested lambdas, body references outer opened binder.
      const TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TBound(2))),
      // Nested lambdas mixing references.
      const TLam(
        TType(LLevel(0)),
        TLam(TType(LLevel(0)), TApp(TBound(2), TApp(TBound(1), TBound(0)))),
      ),
      // Pi with body using the bound variable dependently.
      const TPi(TType(LLevel(0)), TBound(0)),
      // Mixed Pi and Lam.
      const TPi(TType(LLevel(0)), TLam(TBound(0), TBound(1))),
      // Ten-deep binders with a reference to the outermost.
      _nestedLam(10, const TBound(10)),
    ];

    for (var i = 0; i < cases.length; i++) {
      final t = cases[i];
      test('case $i', () {
        final opened = openTerm(t, 'fresh');
        final closed = closeTerm(opened, 'fresh');
        expect(closed, t);
      });
    }
  });

  group('Round-trip: open(close(t, x), x) == t', () {
    // Terms that may or may not contain TFree("x"). The property holds
    // because close makes TFree(x) into TBound(_), and open puts it back.
    final cases = <Term>[
      const TFree('x'),
      const TFree('other'),
      const TApp(TFree('x'), TFree('x')),
      const TLam(TType(LLevel(0)), TFree('x')),
      const TLam(TType(LLevel(0)), TApp(TFree('x'), TBound(0))),
      const TPi(TFree('x'), TFree('x')),
      const TLam(
        TType(LLevel(0)),
        TLam(TType(LLevel(0)), TApp(TFree('x'), TApp(TBound(0), TBound(1)))),
      ),
    ];

    for (var i = 0; i < cases.length; i++) {
      final t = cases[i];
      test('case $i', () {
        final closed = closeTerm(t, 'x');
        final opened = openTerm(closed, 'x');
        expect(opened, t);
      });
    }
  });

  test(
    'openTerm on term without TBound(0) still decrements deeper indices',
    () {
      expect(openTerm(const TBound(5), 'x'), const TBound(4));
    },
  );
}

Term _nestedLam(int depth, Term body) {
  var t = body;
  for (var i = 0; i < depth; i++) {
    t = TLam(const TType(LLevel(0)), t);
  }
  return t;
}
