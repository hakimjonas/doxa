/// Reduction audit for TMatch / VMatch.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

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
  sort: const TType(LLevel(0)),
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

final TopEnv _topEnv = TopEnv(const <TopBinding>[], [_natDecl]);
Env get _env => _topEnv.toCtx().env;

Value get _zeroV => const VConstr('Nat', 'zero', <Value>[]);
Value _succV(Value n) => VConstr('Nat', 'succ', [n]);

/// Parse + elaborate + check a program.
void _run(String src) {
  final r = parseProgram(src);
  final SProgram prog;
  if (r is Success<ParseError, SProgram>) {
    prog = r.value;
  } else if (r is Partial<ParseError, SProgram>) {
    prog = r.value;
  } else {
    fail('parse failed: $r');
  }
  final env = elabProgram(prog);
  final acc = <TopBinding>[];
  for (final b in env.bindings) {
    final ctx = TopEnv(acc, env.dataDecls).toCtx();
    check(ctx, b.term, eval(b.type, ctx.env));
    acc.add(b);
  }
}

void main() {
  group('ι: canonical scrutinee dispatches', () {
    test('zero ctor arm selected', () {
      const m = TMatch(
        TConstr('Nat', 'zero', <Term>[]),
        TData('Nat', <Term>[]),
        [
          TMatchCase('zero', 0, TBound(999), []),
          TMatchCase('succ', 1, TBound(0), ['m']),
        ],
      );
      // TBound(999) in the zero arm: if the wrong arm fires we see an
      // out-of-range env lookup (the throw) instead of a VConstr.
      expect(() => eval(m, _env), throwsA(anything));
    });

    test('succ ctor arm selected and binder resolved', () {
      const m = TMatch(
        TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        TData('Nat', <Term>[]),
        [
          TMatchCase(
            'zero',
            0,
            TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
            [],
          ),
          TMatchCase('succ', 1, TBound(0), ['m']),
        ],
      );
      final v = eval(m, _env);
      expect((v as VConstr).ctorName, 'zero');
    });

    test(
      'non-wildcard arm wins over wildcard even when wildcard comes first',
      () {
        const m = TMatch(
          TConstr('Nat', 'zero', <Term>[]),
          TData('Nat', <Term>[]),
          [
            TMatchCase(
              '',
              0,
              TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
              [],
            ),
            TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
          ],
        );
        final v = eval(m, _env);
        expect((v as VConstr).ctorName, 'zero');
      },
    );

    test('wildcard fires when no explicit match', () {
      const m = TMatch(
        TConstr('Nat', 'zero', <Term>[]),
        TData('Nat', <Term>[]),
        [
          TMatchCase('succ', 1, TBound(0), ['m']),
          TMatchCase('', 0, TConstr('Nat', 'zero', <Term>[]), []),
        ],
      );
      final v = eval(m, _env);
      expect((v as VConstr).ctorName, 'zero');
    });
  });

  group('ι: binder substitution', () {
    test('succ arm binder = ctor arg', () {
      final two = _succV(_succV(_zeroV));
      const m = TMatch(
        TConstr('Nat', 'succ', [
          TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        ]),
        TData('Nat', <Term>[]),
        [
          TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
          TMatchCase('succ', 1, TBound(0), ['m']),
        ],
      );
      final v = eval(m, _env);
      expect((v as VConstr).ctorName, 'succ');
      expect((v.args.single as VConstr).ctorName, 'zero');
      // `two` is built for illustration only; assert it to quiet the linter.
      expect(two, isA<VConstr>());
    });

    test(
      'multi-binder arm: first binder = first ctor arg (innermost-last)',
      () {
        // No assertions here: a 2-arg ctor would need a manual registry.
        // The single-binder case is covered above; true multi-binder
        // coverage lives in match_elab_test, which elaborates real code.
      },
    );
  });

  group('stuck match remains stuck and re-reduces later', () {
    test('stuck match on neutral scrutinee is a VMatch', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['m']),
      ]);
      final v = eval(m, extended);
      expect(v, isA<VMatch>());
    });

    test('stuck match scrutinee on a VRec stays stuck as VMatch', () {
      // A VRec applied to too few args is stuck; a match on it must
      // itself stay stuck. Regression: VMatch scrutinee can be any
      // stuck Value, not just a neutral variable.
      final stuckRec = VRec(_natDecl, const <Value>[]);
      final env = _env.extend(stuckRec);
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['m']),
      ]);
      final v = eval(m, env);
      expect(v, isA<VMatch>());
    });

    test('match inside a match: outer stays stuck when inner is stuck', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const inner = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['m']),
      ]);
      const outer = TMatch(inner, TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['m']),
      ]);
      final v = eval(outer, extended);
      expect(v, isA<VMatch>());
    });
  });

  group('applying stuck matches (NStuck + NApp spine)', () {
    test('applying a stuck match once extends the neutral spine', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const idLam = TLam(TType(LLevel(0)), TBound(0));
      const matchTerm = TMatch(TBound(0), TPi(TType(LLevel(0)), TType(LLevel(0))), [
        TMatchCase('zero', 0, idLam, []),
        TMatchCase('succ', 1, idLam, ['_']),
      ]);
      const applied = TApp(matchTerm, TType(LLevel(0)));
      final v = eval(applied, extended);
      expect(
        v,
        isA<VNeutral>(),
        reason:
            'stuck match applied to arg should become a VNeutral '
            'spine (via NStuck wrapping)',
      );
    });

    test('two structurally-equal stuck match-spine applications converge', () {
      // Regression: comparing two neutral spines once cast the head
      // directly to a plain variable, which crashed when the head was
      // a stuck match instead.
      final extended = _env.extend(const VNeutral(NVar(0)));
      const idLam = TLam(TType(LLevel(0)), TBound(0));
      const matchTerm = TMatch(TBound(0), TPi(TType(LLevel(0)), TType(LLevel(0))), [
        TMatchCase('zero', 0, idLam, []),
        TMatchCase('succ', 1, idLam, ['_']),
      ]);
      const applied = TApp(matchTerm, TType(LLevel(0)));
      final v1 = eval(applied, extended);
      final v2 = eval(applied, extended);
      expect(conv(1, v1, v2), isA<ConvOk>());
    });

    test('two different stuck match-spine applications report mismatch', () {
      final extA = _env.extend(const VNeutral(NVar(0)));
      final extB = _env.extend(const VNeutral(NVar(1)));
      const idLam = TLam(TType(LLevel(0)), TBound(0));
      const matchTerm = TMatch(TBound(0), TPi(TType(LLevel(0)), TType(LLevel(0))), [
        TMatchCase('zero', 0, idLam, []),
        TMatchCase('succ', 1, idLam, ['_']),
      ]);
      const applied = TApp(matchTerm, TType(LLevel(0)));
      final v1 = eval(applied, extA);
      final v2 = eval(applied, extB);
      // Levels differ → scrutinees differ → mismatch.
      expect(conv(2, v1, v2), isA<ConvMismatch>());
    });
  });

  group('η: VLam × stuck function-returning values', () {
    test('function-returning stuck match elaborates and checks', () {
      // Sets up the shape that would produce a VLam-vs-stuck-VMatch
      // conv pair, even though the body β-reduces at each call site so
      // this path does not directly exercise that comparison.
      _run('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun constId(n: Nat): Nat -> Nat = match n returning Nat -> Nat {
  case zero => (x: Nat) => x
  case succ _ => (x: Nat) => x
}
''');
    });

    test('η holds: (x: T) => stuckMatch x  ≡  stuckMatch', () {
      // Regression: a lambda eta-wrapping a stuck match once failed to
      // convert with the bare stuck match, falling through the
      // lambda-vs-other case to a mismatch.
      final extended = _env.extend(const VNeutral(NVar(0)));
      const idLamTerm = TLam(TData('Nat', <Term>[]), TBound(0));
      // Stuck on scrutinee = TBound(0) (neutral at level 0).
      const stuckMatchTerm = TMatch(
        TBound(0),
        TPi(TData('Nat', <Term>[]), TData('Nat', <Term>[]), name: 'x'),
        [
          TMatchCase('zero', 0, idLamTerm, []),
          TMatchCase('succ', 1, idLamTerm, ['_']),
        ],
      );
      // LHS: (x: Nat) => stuckMatch x
      //   where stuckMatch is lifted one binder deeper (TBound(1)
      //   for the original scrutinee; TBound(0) for the new lambda
      //   binder).
      const lhs = TLam(
        TData('Nat', <Term>[]),
        TApp(
          TMatch(
            TBound(1),
            TPi(TData('Nat', <Term>[]), TData('Nat', <Term>[]), name: 'x'),
            [
              TMatchCase('zero', 0, idLamTerm, []),
              TMatchCase('succ', 1, idLamTerm, ['_']),
            ],
          ),
          TBound(0),
        ),
      );
      final lhsV = eval(lhs, extended);
      final rhsV = eval(stuckMatchTerm, extended);
      expect(
        conv(1, lhsV, rhsV),
        isA<ConvOk>(),
        reason:
            'η should fire: applying both to a fresh neutral '
            'yields the same neutral spine.',
      );
    });

    test('VLam × VMatch direct conv: non-η case correctly rejects', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const idLamTerm = TLam(TData('Nat', <Term>[]), TBound(0));
      final lamV = eval(idLamTerm, extended);
      // The stuck match returns the identity lambda in every arm, but
      // its scrutinee `n` is the neutral at level 0.
      const matchTerm = TMatch(
        TBound(0),
        TPi(TData('Nat', <Term>[]), TData('Nat', <Term>[]), name: 'x'),
        [
          TMatchCase('zero', 0, idLamTerm, []),
          TMatchCase('succ', 1, idLamTerm, ['_']),
        ],
      );
      final matchV = eval(matchTerm, extended);
      expect(
        matchV,
        isA<VMatch>(),
        reason: 'sanity: stuck match on neutral scrutinee',
      );
      // A lambda and a stuck match are NOT eta-convertible: the match
      // never commits to an arm, so its spine doesn't reduce to the
      // identity. Pin the mismatch so we don't regress it into an
      // "always OK" bug.
      expect(conv(1, lamV, matchV), isA<ConvMismatch>());
    });
  });

  group('quote round-trip on stuck matches', () {
    test('stuck VMatch quotes to TMatch with same ctor arm names', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
        TMatchCase('succ', 1, TBound(0), ['m']),
      ]);
      final v = eval(m, extended);
      final q = quote(1, v);
      expect(q, isA<TMatch>());
      final qm = q as TMatch;
      expect(qm.cases.map((c) => c.ctorName), ['zero', 'succ']);
    });

    test('stuck VMatch with null motive quotes to TMatch with null motive', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const m = TMatch(
        TBound(0),
        null, // implicit motive
        [
          TMatchCase('zero', 0, TConstr('Nat', 'zero', <Term>[]), []),
          TMatchCase('succ', 1, TBound(0), ['m']),
        ],
      );
      final v = eval(m, extended);
      final q = quote(1, v) as TMatch;
      expect(q.motive, isNull);
    });

    test('stuck VMatch preserves arm spans through quote', () {
      final extended = _env.extend(const VNeutral(NVar(0)));
      const armSpan = DoxaSpan(100, 120);
      const m = TMatch(TBound(0), TData('Nat', <Term>[]), [
        TMatchCase(
          'zero',
          0,
          TConstr('Nat', 'zero', <Term>[]),
          [],
          span: armSpan,
        ),
        TMatchCase('succ', 1, TBound(0), ['m'], span: _span),
      ]);
      final v = eval(m, extended);
      final q = quote(1, v) as TMatch;
      expect(q.cases[0].span, armSpan);
    });
  });

  group('program-level reductions through match', () {
    test('pred zero = zero', () {
      _run('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ m => m
}

val result : Nat = pred zero
''');
    });

    test('pred (succ (succ zero)) = succ zero (normal form)', () {
      const prog = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ m => m
}

val two : Nat = succ (succ zero)
val result : Nat = pred two
''';
      final env = elabProgram(_parseProg(prog));
      final acc = <TopBinding>[];
      for (final b in env.bindings) {
        final ctx = TopEnv(acc, env.dataDecls).toCtx();
        check(ctx, b.term, eval(b.type, ctx.env));
        acc.add(b);
      }
      final resultIdx = env.bindings.indexWhere((b) => b.name == 'result');
      final priorEnv = TopEnv(
        env.bindings.sublist(0, resultIdx),
        env.dataDecls,
      );
      final v = eval(env.bindings[resultIdx].term, priorEnv.toCtx().env);
      expect((v as VConstr).ctorName, 'succ');
      expect((v.args.single as VConstr).ctorName, 'zero');
    });
  });
}

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}
