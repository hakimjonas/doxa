import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SExpr _parse(String src) {
  final r = parseExpr(src);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}

// ---------------------------------------------------------------------------
// Fixtures for data-type tests
// ---------------------------------------------------------------------------

const _span = DoxaSpan.synthetic;

// Surface AST for `data Nat : Type { zero : Nat; succ : Nat -> Nat }`.
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

// Elaborated form of `data Nat`.
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

// Surface AST for `data Vec (A : Type) : Nat -> Type { vnil : Vec A zero; ... }`.
const SDataKind _vecSource = SDataKind(
  'Vec',
  <(String, SExpr?)>[('_', null)],
  SExpr(
    SPiKind(null, SExpr(SIdentKind('Nat'), _span), SExpr(STypeKind(0), _span)),
    _span,
  ),
  [
    SCtorDecl('vnil', SExpr(SIdentKind('Vec'), _span), _span),
    SCtorDecl(
      'vcons',
      SExpr(
        SPiKind(
          null,
          SExpr(STypeKind(0), _span),
          SExpr(SIdentKind('Vec'), _span),
        ),
        _span,
      ),
      _span,
    ),
  ],
);

// Elaborated form of `data Vec (A : Type) : Nat -> Type`.
final DataDecl _vecDecl = DataDecl(
  name: 'Vec',
  params: const [TelescopeEntry('_', TType(LLevel(0)), _span)],
  indices: const [TelescopeEntry('_', TData('Nat', <Term>[]), _span)],
  sort: const TType(LLevel(0)),
  ctors: [
    CtorDecl(
      dataName: 'Vec',
      name: 'vnil',
      args: const <TelescopeEntry>[],
      resultIndices: const [TConstr('Nat', 'zero', <Term>[])],
      source: _vecSource.ctors[0],
      span: _span,
    ),
    CtorDecl(
      dataName: 'Vec',
      name: 'vcons',
      args: const [
        TelescopeEntry(null, TData('Nat', <Term>[]), _span),
        TelescopeEntry(null, TType(LLevel(0)), _span),
        TelescopeEntry(
          null,
          TData('Vec', [TType(LLevel(0)), TData('Nat', <Term>[])]),
          _span,
        ),
      ],
      resultIndices: const [TConstr('Nat', 'succ', <Term>[])],
      source: _vecSource.ctors[1],
      span: _span,
    ),
  ],
  paramsCovariant: const [true],
  source: _vecSource,
  span: _span,
);

List<DataDecl> _natDataDecls() => [_natDecl];

/// The prelude's declarations (`Eq`, `Acc`) plus `Nat`: the registry a
/// quotient test needs.
List<DataDecl> _natEqDecls() => [...loadPrelude().dataDecls, _natDecl];

/// A context with `Nat` and `Eq` registered and no binders.
Ctx _natEqCtx() =>
    CNil.withRegistries(dataDecls: _natEqDecls(), topBindings: const {});

/// A top environment with `Nat` and `Eq` registered and no bindings.
TopEnv _natEnv() => TopEnv(const [], _natEqDecls(), const {}, const {});

/// The relation `(a: Nat) => (b: Nat) => Eq Nat a b`, as a term.
Term _natRelTerm() => const TLam(
  TData('Nat', <Term>[]),
  TLam(
    TData('Nat', <Term>[]),
    TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
  ),
);

/// The relation `(a: Nat) => (b: Nat) => Eq Nat a b`, as a value.
Value _natRel() => eval(
  const TLam(
    TData('Nat', <Term>[]),
    TLam(
      TData('Nat', <Term>[]),
      TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
    ),
  ),
  ENil.withRegistries(dataDecls: _natEqDecls(), topBindings: const {}),
);

/// `Quot(Nat, rel)`, as a value.
Value _natQuot() => VQuot(const VData('Nat', <Value>[]), _natRel());

/// `mk (zero: Nat)`, as a value.
const Value _mkZero = VQuotMk(VConstr('Nat', 'zero', <Value>[]));

/// `refl Nat zero : Eq Nat zero zero`.
Term _natRefl() => const TConstr('Eq', 'refl', [
  TData('Nat', <Term>[]),
  TConstr('Nat', 'zero', []),
]);

/// `(x: Nat) -> (y: Nat) -> R x y -> Eq Nat x y`, with [proofBody] as the
/// innermost proof. `TBound(0)` is `h : R x y`, which is the expected
/// equation, so passing it through is the identity compatibility proof.
Term _natCompatProof(Term proofBody) => TLam(
  const TData('Nat', <Term>[]),
  TLam(
    const TData('Nat', <Term>[]),
    TLam(
      const TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
      proofBody,
    ),
  ),
);

/// `Quot(Nat, rel) -> Nat`, as a value.
Value _natLiftType() => eval(
  const TPi(
    TQuot(
      TData('Nat', <Term>[]),
      TLam(
        TData('Nat', <Term>[]),
        TLam(
          TData('Nat', <Term>[]),
          TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
        ),
      ),
    ),
    TData('Nat', <Term>[]),
  ),
  ENil.withRegistries(dataDecls: _natEqDecls(), topBindings: const {}),
);

List<DataDecl> _vecDataDecls() => [_vecDecl];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('quotient types', () {
    test('basic formation - Quot typechecks', () {
      final v = eval(
        const TQuot(
          TType(LLevel(0)),
          TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TProp())),
        ),
        const ENil(),
      );
      expect(v, isA<VQuot>());
      final vq = v as VQuot;
      expect(vq.carrier, isA<VType>());
      expect(vq.relation, isA<VPi>());
    });

    test('mk injection', () {
      final v = eval(const TQuotMk(TType(LLevel(0))), const ENil());
      expect(v, isA<VQuotMk>());
      expect((v as VQuotMk).arg, isA<VType>());
    });

    test('lift applies to an injection by ι-reduction', () {
      // `lift f h` evaluates to a function value; applying it to `mk a`
      // computes `f a`. The compatibility proof is not consulted.
      final liftV = eval(
        const TQuotLift(TLam(TType(LLevel(0)), TBound(0)), TProp()),
        const ENil(),
      );
      expect(liftV, isA<VQuotLift>());
      final applied = apply(liftV, const VQuotMk(VType(LLevel(0))));
      expect(applied, isA<VType>());
      expect((applied as VType).level, equals(const LLevel(0)));
    });

    test('VQuotMk not definitionally equal for different args', () {
      final result = conv(
        0,
        const VQuotMk(VType(LLevel(0))),
        const VQuotMk(VType(LLevel(1))),
      );
      expect(result, isA<ConvMismatch>());
    });

    test('VQuotMk identical args are definitionally equal', () {
      const arg = VType(LLevel(0));
      expect(conv(0, const VQuotMk(arg), const VQuotMk(arg)), isA<ConvOk>());
    });

    test('VQuotMk equal args compare structurally, not by identity', () {
      // Two separately evaluated but equal arguments are distinct objects;
      // conversion descends into them rather than testing identity.
      final a1 = eval(const TConstr('Nat', 'zero', []), const ENil());
      final a2 = eval(const TConstr('Nat', 'zero', []), const ENil());
      expect(identical(a1, a2), isFalse);
      expect(conv(0, VQuotMk(a1), VQuotMk(a2)), isA<ConvOk>());
    });

    test('round-trip eval -> quote -> eval', () {
      const t = TQuot(
        TType(LLevel(0)),
        TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TProp())),
      );
      final v = eval(t, const ENil());
      final quoted = quote(0, v);
      expect(quoted, isA<TQuot>());
      expect(eval(quoted, const ENil()), isA<VQuot>());
    });

    test('neutral QuotLift stays stuck and quotes correctly', () {
      const stuck = VQuotLift(
        VLam(VType(LLevel(0)), Closure(ENil(), TBound(0))),
        VProp(),
      );
      expect(quote(1, stuck), isA<TQuotLift>());
    });

    test('a stuck lift applied to a neutral keeps the lift as its head', () {
      const liftV = VQuotLift(
        VLam(VType(LLevel(0)), Closure(ENil(), TBound(0))),
        VProp(),
      );
      final result = apply(liftV, const VNeutral(NVar(0)));
      expect(result, isA<VNeutral>());
      final quoted = quote(1, result);
      // `lift f h q`, not `f q`: the head is the lift itself.
      expect(quoted, isA<TApp>());
      expect((quoted as TApp).fn, isA<TQuotLift>());
    });

    test('VQuot carriers compare structurally in conv', () {
      expect(
        conv(
          0,
          const VQuot(VType(LLevel(0)), VProp()),
          const VQuot(VType(LLevel(0)), VProp()),
        ),
        isA<ConvOk>(),
      );
    });

    test('VQuot different carriers do not convert', () {
      expect(
        conv(
          0,
          const VQuot(VType(LLevel(0)), VProp()),
          const VQuot(VType(LLevel(1)), VProp()),
        ),
        isA<ConvMismatch>(),
      );
    });

    test('TQuot infers as VType', () {
      final q = TQuot(const TData('Nat', <Term>[]), _natRelTerm());
      expect(infer(_natEqCtx(), q), isA<VType>());
    });

    test('TQuotMk is rejected in infer mode', () {
      expect(
        () => infer(_natEqCtx(), const TQuotMk(TConstr('Nat', 'zero', []))),
        throwsA(isA<QuotMkInInferMode>()),
      );
    });

    test('TQuotMk checks against a quotient type', () {
      expect(
        check(
          _natEqCtx(),
          const TQuotMk(TConstr('Nat', 'zero', [])),
          _natQuot(),
        ),
        isA<VQuot>(),
      );
    });

    test('TQuotMk against a non-quotient expected type is rejected', () {
      expect(
        () => check(
          _natEqCtx(),
          const TQuotMk(TConstr('Nat', 'zero', [])),
          const VData('Nat', <Value>[]),
        ),
        throwsA(isA<NotAQuotient>()),
      );
    });

    test('TQuotMk rejects an element outside the carrier', () {
      expect(
        () => check(
          _natEqCtx(),
          const TQuotMk(TConstr('Nat', 'succ', [TData('Nat', <Term>[])])),
          VQuot(const VData('Bool', <Value>[]), _natRel()),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('infer TQuot rejects non-sort carrier', () {
      const q = TQuot(
        TLam(TType(LLevel(0)), TBound(0)),
        TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TProp())),
      );
      expect(() => infer(_natEqCtx(), q), throwsA(isA<NotAType>()));
    });

    test('infer TQuot rejects a relation that is not a relation', () {
      // `Type` is a sort, not a binary relation on `Nat`.
      expect(
        () => infer(
          _natEqCtx(),
          const TQuot(TData('Nat', <Term>[]), TType(LLevel(0))),
        ),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('TQuotLift is rejected in infer mode', () {
      expect(
        () => infer(
          _natEqCtx(),
          const TQuotLift(TLam(TData('Nat', <Term>[]), TBound(0)), TProp()),
        ),
        throwsA(isA<QuotLiftInInferMode>()),
      );
    });

    test('TQuotLift checks against a function from a quotient', () {
      // `lift (n => n) (x => y => h => h) : Quot(Nat, rel) -> Nat`.
      final expected = _natLiftType();
      final term = TQuotLift(
        const TLam(TData('Nat', <Term>[]), TBound(0)),
        _natCompatProof(const TBound(0)),
      );
      expect(check(_natEqCtx(), term, expected), isA<VPi>());
    });

    test('a lift function that does not respect the relation is rejected', () {
      // `const zero` sends both classes to zero, so it needs
      // `Eq Nat zero zero` from a relation proof it does not have.
      final term = TQuotLift(
        const TLam(TData('Nat', <Term>[]), TConstr('Nat', 'zero', [])),
        _natCompatProof(const TBound(0)),
      );
      expect(
        () => check(_natEqCtx(), term, _natLiftType()),
        throwsA(isA<QuotFnNotRespectingRelation>()),
      );
    });

    test('TQuotLift against a non-function expected type is rejected', () {
      expect(
        () => check(
          _natEqCtx(),
          const TQuotLift(TLam(TData('Nat', <Term>[]), TBound(0)), TProp()),
          const VData('Nat', <Value>[]),
        ),
        throwsA(isA<NotAFunction>()),
      );
    });

    test('TQuotLift with a result type that reads the quotient binder is '
        'rejected', () {
      // `(q: Quot(Nat, rel)) -> Eq (Quot(Nat, rel)) q q`: the codomain
      // mentions the binder, which would be a dependent elimination.
      final expected = eval(
        const TPi(
          TQuot(
            TData('Nat', <Term>[]),
            TLam(
              TData('Nat', <Term>[]),
              TLam(
                TData('Nat', <Term>[]),
                TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
              ),
            ),
          ),
          TData('Eq', [
            TQuot(
              TData('Nat', <Term>[]),
              TLam(
                TData('Nat', <Term>[]),
                TLam(
                  TData('Nat', <Term>[]),
                  TData('Eq', [TData('Nat', <Term>[]), TBound(1), TBound(0)]),
                ),
              ),
            ),
            TBound(0),
            TBound(0),
          ]),
        ),
        ENil.withRegistries(dataDecls: _natEqDecls(), topBindings: const {}),
      );
      final term = TQuotLift(
        const TLam(TData('Nat', <Term>[]), TBound(0)),
        _natCompatProof(const TBound(0)),
      );
      expect(
        () => check(_natEqCtx(), term, expected),
        throwsA(isA<QuotLiftNeedsConstantResult>()),
      );
    });

    test('TQuotLift against a function not from a quotient is rejected', () {
      expect(
        () => check(
          _natEqCtx(),
          const TQuotLift(TLam(TData('Nat', <Term>[]), TBound(0)), TProp()),
          eval(
            const TPi(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
            ENil.withRegistries(
              dataDecls: _natEqDecls(),
              topBindings: const {},
            ),
          ),
        ),
        throwsA(isA<NotAQuotient>()),
      );
    });

    test('TQuotSound checks against an equality of injections', () {
      final term = TQuotSound(
        const TConstr('Nat', 'zero', []),
        const TConstr('Nat', 'zero', []),
        _natRefl(),
      );
      final expected = VData('Eq', [_natQuot(), _mkZero, _mkZero]);
      expect(check(_natEqCtx(), term, expected), isA<VData>());
    });

    test('TQuotSound is rejected in infer mode', () {
      expect(
        () => infer(
          _natEqCtx(),
          TQuotSound(
            const TConstr('Nat', 'zero', []),
            const TConstr('Nat', 'zero', []),
            _natRefl(),
          ),
        ),
        throwsA(isA<QuotSoundInInferMode>()),
      );
    });

    test('TQuotSound against a non-equality is rejected', () {
      expect(
        () => check(
          _natEqCtx(),
          TQuotSound(
            const TConstr('Nat', 'zero', []),
            const TConstr('Nat', 'zero', []),
            _natRefl(),
          ),
          const VData('Nat', <Value>[]),
        ),
        throwsA(isA<QuotSoundNeedsInjection>()),
      );
    });

    test('TQuotSound with a witness of the wrong relation is rejected', () {
      // The expected relation is `Eq Nat zero zero`; this witness proves
      // `Eq Nat (succ zero) (succ zero)`.
      const term = TQuotSound(
        TConstr('Nat', 'zero', []),
        TConstr('Nat', 'zero', []),
        TConstr('Eq', 'refl', [
          TData('Nat', <Term>[]),
          TConstr('Nat', 'succ', [TData('Nat', <Term>[])]),
        ]),
      );
      final expected = VData('Eq', [_natQuot(), _mkZero, _mkZero]);
      expect(
        () => check(_natEqCtx(), term, expected),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('TQuotSound rejects a cached injection the expected equation '
        'does not name', () {
      // Forged term: the cached left injection names `succ zero`, while
      // the expected equation names `mk zero` on both sides. The witness
      // is valid for the expected relation, so only the cached operand
      // check can reject the term.
      final term = TQuotSound(
        const TConstr('Nat', 'succ', [TData('Nat', <Term>[])]),
        const TConstr('Nat', 'zero', []),
        _natRefl(),
      );
      final expected = VData('Eq', [_natQuot(), _mkZero, _mkZero]);
      expect(
        () => check(_natEqCtx(), term, expected),
        throwsA(
          isA<TypeMismatch>()
              .having((e) => e.got, 'got', isA<VConstr>())
              .having((e) => e.expected, 'expected', isA<VConstr>()),
        ),
      );
    });

    test('TQuotSound rejects a cached right injection the expected '
        'equation does not name', () {
      // Mirror of the left case: the right operand is forged.
      final term = TQuotSound(
        const TConstr('Nat', 'zero', []),
        const TConstr('Nat', 'succ', [TData('Nat', <Term>[])]),
        _natRefl(),
      );
      final expected = VData('Eq', [_natQuot(), _mkZero, _mkZero]);
      expect(
        () => check(_natEqCtx(), term, expected),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('VQuotSound proofs are definitionally equal by irrelevance', () {
      final ctx = _natEqCtx();
      final soundV = eval(
        TQuotSound(
          const TConstr('Nat', 'zero', []),
          const TConstr('Nat', 'zero', []),
          _natRefl(),
        ),
        ctx.env,
      );
      // A different proof of the same proposition: `refl`.
      final reflV = eval(_natRefl(), ctx.env);
      expect(
        conv(ctx.level, soundV, reflV, dataDecls: ctx.dataDecls),
        isA<ConvOk>(),
      );
    });

    // --- Parser tests ---

    test('parse Quot(Type, ...)', () {
      final e = _parse('Quot(Type, (a: Type) -> (b: Type) -> Prop)');
      expect(e.kind, isA<SQuotKind>());
      final qk = e.kind as SQuotKind;
      expect(qk.carrier.kind, isA<STypeKind>());
      expect(qk.relation.kind, isA<SPiKind>());
    });

    test('parse mk a', () {
      final e = _parse('mk Type');
      expect(e.kind, isA<SQuotMkKind>());
    });

    test('parse lift(fn, proof)', () {
      final e = _parse('lift((x: Type) => x, (y: Type) => Prop)');
      expect(e.kind, isA<SQuotLiftKind>());
    });

    // --- Elaboration tests ---

    test('elaborate Quot expression', () {
      final e = _parse('Quot(Nat, (a: Nat) => (b: Nat) => Eq Nat a b)');
      final term = elabExpr(_natEnv(), e);
      expect(term, isA<TQuot>());
      final tq = term as TQuot;
      expect(tq.carrier, isA<TData>());
      expect(tq.relation, isA<TLam>());
    });

    test('elaborate and infer Quot type', () {
      final e = _parse('Quot(Nat, (a: Nat) => (b: Nat) => Eq Nat a b)');
      final env = _natEnv();
      final term = elabExpr(env, e);
      expect(infer(env.toCtx(), term), isA<VType>());
    });

    test('elaborating mk without an expected type names the form', () {
      final e = _parse('mk Type');
      expect(
        () => elabExpr(TopEnv.empty, e),
        throwsA(
          isA<QuotientNeedsExpectedType>().having(
            (err) => err.form,
            'form',
            'mk',
          ),
        ),
      );
    });

    test('elaborating lift without an expected type names the form', () {
      final e = _parse('lift(Type, (x: Type) => x)');
      expect(
        () => elabExpr(TopEnv.empty, e),
        throwsA(
          isA<QuotientNeedsExpectedType>().having(
            (err) => err.form,
            'form',
            'lift',
          ),
        ),
      );
    });

    test('Quot.mk is recognized as mk keyword', () {
      final e = _parse('mk (x: Type) => x');
      expect(e.kind, isA<SQuotMkKind>());
    });

    test('Quot keyword parse error on wrong arity', () {
      final r = parseExpr('Quot(Type)');
      expect(r, isA<Failure<ParseError, SExpr>>());
    });

    // --- Quotient singleton elimination / Lean 3 soundness tests ---

    test(
      'Quot.lift into Type with Prop carrier succeeds (quotients are Type-sorted)',
      () {
        // `(a: Prop) => (b: Prop) => a` is Prop-valued, so it is a
        // relation on Prop.
        const q = TQuot(TProp(), TLam(TProp(), TLam(TProp(), TBound(1))));
        const ctx = CNil.withRegistries(dataDecls: [], topBindings: {});
        final qType = infer(ctx, q);
        expect(qType, isA<VType>());
        // The carrier sort is VType(LLevel(1)) (Prop : Type 1), so the quotient sorts at Type 1.
        expect((qType as VType).level, equals(const LLevel(1)));
      },
    );

    test(
      'Quot with Prop carrier is Type-sorted, not Prop-sorted (Lean 3 fix is architectural)',
      () {
        const q = TQuot(TProp(), TLam(TProp(), TLam(TProp(), TBound(1))));
        const ctx = CNil.withRegistries(dataDecls: [], topBindings: {});
        final qType = infer(ctx, q);
        expect(qType, isA<VType>());
        expect((qType as VType).level, equals(const LLevel(1)));

        // A Type-0 carrier keeps the quotient at Type 0.
        final q2 = TQuot(const TData('Nat', <Term>[]), _natRelTerm());
        final q2Type = infer(_natEqCtx(), q2);
        expect((q2Type as VType).level, equals(const LLevel(0)));
      },
    );

    test('a lift whose function does not respect the relation is rejected '
        'in check mode', () {
      // A well-formed quotient, a function that ignores its argument, and
      // a proof that does not establish the required equation.
      final ctx = _natEqCtx();
      const term = TQuotLift(
        TLam(TData('Nat', <Term>[]), TConstr('Nat', 'zero', [])),
        TLam(TData('Nat', <Term>[]), TLam(TData('Nat', <Term>[]), TProp())),
      );
      expect(
        () => check(ctx, term, _natLiftType()),
        throwsA(isA<QuotFnNotRespectingRelation>()),
      );
    });

    test('TQuotLift checked against a non-function is rejected', () {
      final ctx = _natEqCtx();
      final term = TQuotLift(
        const TLam(TData('Nat', <Term>[]), TBound(0)),
        _natCompatProof(const TBound(0)),
      );
      expect(
        () => check(ctx, term, const VData('Nat', <Value>[])),
        throwsA(isA<NotAFunction>()),
      );
    });

    // --- Quotient-in-match tests ---

    test('TQuot inside TMatch case body evaluates correctly', () {
      const t = TMatch(TConstr('Nat', 'zero', []), null, [
        TMatchCase(
          'zero',
          0,
          TQuot(
            TType(LLevel(0)),
            TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TProp())),
          ),
          [],
          span: DoxaSpan.synthetic,
        ),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _natDataDecls(),
        topBindings: const {},
      );
      final v = eval(t, env);
      expect(v, isA<VQuot>());
    });

    test('TQuotMk inside indexed-family match arm evaluates correctly', () {
      const t = TMatch(TConstr('Vec', 'vnil', [TType(LLevel(0))]), null, [
        TMatchCase(
          'vnil',
          0,
          TQuotMk(TConstr('Nat', 'zero', [])),
          [],
          span: DoxaSpan.synthetic,
        ),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _vecDataDecls(),
        topBindings: const {},
      );
      final v = eval(t, env);
      expect(v, isA<VQuotMk>());
    });

    test('quotient in match round-trips through eval -> quote -> eval', () {
      const t = TMatch(TConstr('Nat', 'zero', []), null, [
        TMatchCase(
          'zero',
          0,
          TQuot(
            TType(LLevel(0)),
            TPi(TType(LLevel(0)), TPi(TType(LLevel(0)), TProp())),
          ),
          [],
          span: DoxaSpan.synthetic,
        ),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _natDataDecls(),
        topBindings: const {},
      );
      final v = eval(t, env);
      final quoted = quote(0, v);
      expect(quoted, isA<TQuot>());
      final reEval = eval(quoted, env);
      expect(reEval, isA<VQuot>());
    });
  });
}
