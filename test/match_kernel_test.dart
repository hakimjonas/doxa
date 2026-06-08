/// Kernel `TMatch` + `VMatch` tests (equality, ι-reduction, stuck/quote, conv).
///
/// These construct TMatch terms directly using a registry-populated TopEnv
/// and hand-written DataDecls, since elaboration is exercised elsewhere.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fixtures, a hand-built `data Nat` registry entry.
// ---------------------------------------------------------------------------

const _span = DoxaSpan.synthetic;

const SDataKind _natSource =
    SDataKind('Nat', <(String, SExpr?)>[], SExpr(STypeKind(0), _span), [
      SCtorDecl('zero', SExpr(SIdentKind('Nat'), _span), _span),
      SCtorDecl(
        'succ',
        SExpr(
          SPiKind(
            null,
            SExpr(SIdentKind('Nat'), _span),
            SExpr(SIdentKind('Nat'), _span),
          ),
          _span,
        ),
        _span,
      ),
    ]);

final DataDecl _natDecl = DataDecl(
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
      source: _natSource.ctors[0],
      span: _span,
    ),
    CtorDecl(
      dataName: 'Nat',
      name: 'succ',
      args: const [TelescopeEntry(null, TData('Nat', <Term>[]), _span)],
      resultIndices: const <Term>[],
      source: _natSource.ctors[1],
      span: _span,
    ),
  ],
  paramsCovariant: const <bool>[],
  source: _natSource,
  span: _span,
);

/// A TopEnv containing only the Nat registry.
final TopEnv _topEnv = TopEnv(const <TopBinding>[], [_natDecl]);
Env get _env => _topEnv.toCtx().env;

/// Nat values for convenience.
const Value _zeroV = VConstr('Nat', 'zero', <Value>[]);
Value _succV(Value n) => VConstr('Nat', 'succ', [n]);

// ---------------------------------------------------------------------------
// Helpers to build match terms.
// ---------------------------------------------------------------------------

/// `match m { case zero => n case succ m_ => succ m_ }`, returns `n`
/// when `m = zero`, the predecessor's successor (i.e. `m` again) when
/// `m = succ m_`. The identity on Nat, but exercises both
/// arms and uses the binder.
TMatch _natIdMatch() => const TMatch(
  TBound(1), // m
  TData('Nat', <Term>[]), // motive (ignored at eval time)
  [
    TMatchCase(
      'zero',
      0,
      TBound(0), // `n` at depth 0 outside the arm, see builder
      <String?>[],
    ),
    TMatchCase(
      'succ',
      1,
      // inside this arm, TBound(0) is `m_` (the ctor arg), TBound(1)
      // is `n`, TBound(2) is `m`. The arm body rebuilds succ m_.
      TConstr('Nat', 'succ', [TBound(0)]),
      <String?>['m_'],
    ),
  ],
);

void main() {
  group('TMatch equality + hashCode', () {
    test('identical match terms compare equal', () {
      const sc = TBound(0);
      const mot = TData('Nat', <Term>[]);
      const m1 = TMatch(sc, mot, [TMatchCase('zero', 0, TBound(1), [])]);
      const m2 = TMatch(sc, mot, [TMatchCase('zero', 0, TBound(1), [])]);
      expect(m1, m2);
      expect(m1.hashCode, m2.hashCode);
    });

    test('different scrutinee → not equal', () {
      const mot = TData('Nat', <Term>[]);
      const m1 = TMatch(TBound(0), mot, <TMatchCase>[]);
      const m2 = TMatch(TBound(1), mot, <TMatchCase>[]);
      expect(m1, isNot(m2));
    });

    test('different case body → not equal', () {
      const sc = TBound(0);
      const mot = TData('Nat', <Term>[]);
      const m1 = TMatch(sc, mot, [TMatchCase('zero', 0, TBound(1), [])]);
      const m2 = TMatch(sc, mot, [TMatchCase('zero', 0, TBound(2), [])]);
      expect(m1, isNot(m2));
    });

    test('binderNames do not participate in equality', () {
      const sc = TBound(0);
      const mot = TData('Nat', <Term>[]);
      const m1 = TMatch(sc, mot, [
        TMatchCase('succ', 1, TBound(0), ['x']),
      ]);
      const m2 = TMatch(sc, mot, [
        TMatchCase('succ', 1, TBound(0), ['y']),
      ]);
      expect(m1, m2);
    });
  });

  group('open / close over TMatch', () {
    test('openTerm substitutes the outer binder, preserves arm binders', () {
      // λ(x). match x { case zero => x case succ p => x }
      // Inside the succ arm, x is TBound(1) (because `p` is at 0), so both
      // the scrutinee and the succ-arm reference of x open to TFree('x').
      const inner = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TBound(0), []),
        TMatchCase('succ', 1, TBound(1), ['p']),
      ]);
      final opened = openTerm(inner, 'x');
      const expected = TMatch(TFree('x'), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TFree('x'), []),
        TMatchCase('succ', 1, TFree('x'), ['p']),
      ]);
      expect(opened, expected);
    });

    test('closeTerm re-binds the free variable under the arm', () {
      const term = TMatch(TFree('x'), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TFree('x'), []),
        TMatchCase('succ', 1, TFree('x'), ['p']),
      ]);
      final closed = closeTerm(term, 'x');
      const expected = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TBound(0), []),
        TMatchCase('succ', 1, TBound(1), ['p']),
      ]);
      expect(closed, expected);
    });
  });

  group('ι-reduction on canonical VConstr scrutinees', () {
    test('match zero { case zero => 42 case succ _ => 99 } = 42', () {
      const m = TMatch(
        TConstr('Nat', 'zero', <Term>[]),
        TData('Nat', <Term>[]),
        [
          TMatchCase(
            'zero',
            0,
            TConstr('Nat', 'succ', [
              TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
            ]),
            [],
          ),
          TMatchCase('succ', 1, TConstr('Nat', 'zero', <Term>[]), ['_']),
        ],
      );
      final v = eval(m, _env);
      expect(v, isA<VConstr>());
      expect((v as VConstr).ctorName, 'succ');
      expect((v.args.single as VConstr).ctorName, 'succ');
      expect(
        ((v.args.single as VConstr).args.single as VConstr).ctorName,
        'zero',
      );
    });

    test('match (succ zero) { case zero => zero case succ p => p } = zero', () {
      const one = TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]);
      const m = TMatch(one, TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      final v = eval(m, _env);
      expect(v, isA<VConstr>());
      expect((v as VConstr).ctorName, 'zero');
    });

    test('nested match: pred on succ (succ zero) = succ zero', () {
      const two = TConstr('Nat', 'succ', [
        TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
      ]);
      const m = TMatch(two, TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      final v = eval(m, _env);
      expect(v, isA<VConstr>());
      final c = v as VConstr;
      expect(c.ctorName, 'succ');
      expect((c.args.single as VConstr).ctorName, 'zero');
    });

    test('wildcard arm catches ctors not listed', () {
      // zero doesn't match the succ arm, so it falls through to wildcard.
      const m = TMatch(
        TConstr('Nat', 'zero', <Term>[]),
        TData('Nat', <Term>[]),
        [
          TMatchCase('succ', 1, TConstr('Nat', 'zero', <Term>[]), ['_']),
          TMatchCase(
            '',
            0,
            TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
            [],
          ),
        ],
      );
      final v = eval(m, _env);
      expect((v as VConstr).ctorName, 'succ');
    });

    test('explicit arm wins over wildcard when both match', () {
      const m = TMatch(
        TConstr('Nat', 'zero', <Term>[]),
        TData('Nat', <Term>[]),
        [
          TMatchCase(
            'zero',
            0,
            TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
            [],
          ),
          TMatchCase('', 0, TConstr('Nat', 'zero', <Term>[]), []),
        ],
      );
      final v = eval(m, _env);
      expect((v as VConstr).ctorName, 'succ');
    });
  });

  group('stuck matches', () {
    test('match on a neutral scrutinee produces VMatch', () {
      // Env has one free binder of type Nat at level 0. TBound(0) resolves
      // to that neutral.
      final extendedEnv = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      final v = eval(m, extendedEnv);
      expect(v, isA<VMatch>());
      final vm = v as VMatch;
      expect(vm.scrutinee, isA<VNeutral>());
      expect(vm.cases, hasLength(2));
    });

    test('quote of a stuck VMatch reproduces its shape', () {
      final extendedEnv = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      final v = eval(m, extendedEnv);
      final q = quote(1, v);
      expect(q, isA<TMatch>());
      final tm = q as TMatch;
      expect(tm.cases, hasLength(2));
      expect(tm.cases[0].ctorName, 'zero');
      expect(tm.cases[1].ctorName, 'succ');
    });
  });

  group('VMatch × VMatch convertibility', () {
    test('two structurally-equal stuck matches converge', () {
      final extendedEnv = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      final v1 = eval(m, extendedEnv);
      final v2 = eval(m, extendedEnv);
      expect(conv(1, v1, v2), _convOk);
    });

    test('different ctor names in arms → mismatch', () {
      final extendedEnv = _env.extend(const VNeutral(NVar(0)));
      const m1 = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
      ]);
      const m2 = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('succ', 1, TConstr('Nat', 'zero', <Term>[]), ['_']),
      ]);
      final v1 = eval(m1, extendedEnv);
      final v2 = eval(m2, extendedEnv);
      expect(conv(1, v1, v2), isA<ConvMismatch>());
    });

    test('different body terms in arms → mismatch', () {
      final extendedEnv = _env.extend(const VNeutral(NVar(0)));
      const m1 = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
      ]);
      const m2 = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase(
          'zero',
          0,
          TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
          [],
        ),
      ]);
      final v1 = eval(m1, extendedEnv);
      final v2 = eval(m2, extendedEnv);
      expect(conv(1, v1, v2), isA<ConvMismatch>());
    });
  });

  group('pretty printer', () {
    test('match with two arms renders surface form without separator', () {
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['p']),
      ]);
      // Provide a placeholder outer scope name so TBound(0) prints
      // sensibly as the scrutinee reference.
      final s = prettyTerm(m, outerDepth: 1, outerNames: const ['m']);
      expect(s, contains('match m'));
      expect(s, contains('case zero => zero'));
      expect(s, contains('case succ p => p'));
      expect(s, isNot(contains(';')));
    });

    test('wildcard arm prints as `case _ => body`', () {
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('', 0, TConstr('Nat', 'zero', <Term>[]), []),
      ]);
      final s = prettyTerm(m, outerDepth: 1, outerNames: const ['x']);
      expect(s, contains('case _ => zero'));
    });
  });

  group('unused helpers: ensure sample compiles', () {
    test('_natIdMatch builds a well-formed TMatch', () {
      // Exercises the fixture so unused-helper warnings don't fire.
      final m = _natIdMatch();
      expect(m.cases, hasLength(2));
      // Evaluate with an explicit Nat scrutinee to check wiring.
      final oneV = _succV(_zeroV);
      final extendedEnv = _env.extend(oneV).extend(_zeroV);
      // After extensions: TBound(0) = zeroV (n), TBound(1) = oneV (m).
      // The match's scrutinee is TBound(1) = m = one, which has ctor
      // `succ`, so we take the succ arm: rebuild succ TBound(0) where
      // TBound(0) inside the arm is the ctor arg m_ = zero. Result:
      // succ zero = one.
      final v = eval(m, extendedEnv);
      expect((v as VConstr).ctorName, 'succ');
      expect((v.args.single as VConstr).ctorName, 'zero');
    });
  });
}

/// Convenience matcher for the `ConvOk` singleton.
final _convOk = predicate<ConvResult>((r) => r is ConvOk, 'is ConvOk');
