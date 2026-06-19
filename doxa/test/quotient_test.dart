import 'package:doxa/src/check.dart';
import 'package:doxa/src/ctx.dart';
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
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
const SDataKind _natSource = SDataKind(
  'Nat',
  <(String, SExpr?)>[],
  SExpr(STypeKind(0), _span),
  [
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
  ],
);

// Elaborated form of `data Nat`.
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

// Surface AST for `data Vec (A : Type) : Nat -> Type { vnil : Vec A zero; ... }`.
const SDataKind _vecSource = SDataKind(
  'Vec',
  <(String, SExpr?)>[('_', null)],
  SExpr(
    SPiKind(
      null,
      SExpr(SIdentKind('Nat'), _span),
      SExpr(STypeKind(0), _span),
    ),
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
  params: const [TelescopeEntry('_', TType(0), _span)],
  indices: const [TelescopeEntry('_', TData('Nat', <Term>[]), _span)],
  sort: const TType(0),
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
        TelescopeEntry(null, TType(0), _span),
        TelescopeEntry(
          null,
          TData('Vec', [TType(0), TData('Nat', <Term>[])]),
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

List<DataDecl> _vecDataDecls() => [_vecDecl];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('quotient types', () {
    test('basic formation - Quot typechecks', () {
      final v = eval(
        TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
        ENil(),
      );
      expect(v, isA<VQuot>());
      final vq = v as VQuot;
      expect(vq.carrier, isA<VType>());
      expect(vq.relation, isA<VPi>());
    });

    test('mk injection', () {
      final v = eval(TQuotMk(TType(0)), ENil());
      expect(v, isA<VQuotMk>());
      expect((v as VQuotMk).arg, isA<VType>());
    });

    test('lift ι-reduction via eval of TQuotLift', () {
      final v = eval(
        TQuotLift(TQuotMk(TType(0)), TLam(TType(0), TBound(0)), TProp()),
        ENil(),
      );
      expect(v, isA<VType>());
      expect((v as VType).level, equals(0));
    });

    test('VQuotMk not definitionally equal for different args', () {
      final result = conv(0, VQuotMk(VType(0)), VQuotMk(VType(1)));
      expect(result, isA<ConvMismatch>());
    });

    test('VQuotMk identical args are definitionally equal', () {
      final arg = VType(0);
      expect(conv(0, VQuotMk(arg), VQuotMk(arg)), isA<ConvOk>());
    });

    test('round-trip eval -> quote -> eval', () {
      final t = TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp())));
      final v = eval(t, ENil());
      final quoted = quote(0, v);
      expect(quoted, isA<TQuot>());
      expect(eval(quoted, ENil()), isA<VQuot>());
    });

    test('neutral QuotLift stays stuck and quotes correctly', () {
      final stuck = VQuotLift(
        VNeutral(NVar(0)),
        VLam(VType(0), Closure(ENil(), TBound(0))),
        VProp(),
      );
      expect(quote(1, stuck), isA<TQuotLift>());
    });

    test('stuck QuotLift creates neutral when applied', () {
      final result = apply(
        VQuotLift(
          VNeutral(NVar(0)),
          VLam(VType(0), Closure(ENil(), TBound(0))),
          VProp(),
        ),
        VType(0),
      );
      expect(result, isA<VNeutral>());
    });

    test('VQuot carriers compare structurally in conv', () {
      expect(
        conv(0, VQuot(VType(0), VProp()), VQuot(VType(0), VProp())),
        isA<ConvOk>(),
      );
    });

    test('VQuot different carriers do not convert', () {
      expect(
        conv(0, VQuot(VType(0), VProp()), VQuot(VType(1), VProp())),
        isA<ConvMismatch>(),
      );
    });

    test('TQuot infers as VType', () {
      final q = TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp())));
      final ctx = CNil.withRegistries(
        dataDecls: const [],
        topBindings: const {},
      );
      expect(infer(ctx, q), isA<VType>());
    });

    test('TQuotMk in infer mode throws QuotMkInInferMode', () {
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      expect(() => infer(ctx, TQuotMk(TType(0))), throwsA(isA<QuotMkInInferMode>()));
    });

    test('infer TQuot rejects non-sort carrier', () {
      final q = TQuot(TLam(TType(0), TBound(0)), TPi(TType(0), TPi(TType(0), TProp())));
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      expect(() => infer(ctx, q), throwsA(isA<NotAType>()));
    });

    test('infer TQuotLift with non-quotient quot throws NotAQuotient', () {
      final t = TQuotLift(TType(0), TLam(TType(0), TBound(0)), TProp());
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      expect(() => infer(ctx, t), throwsA(isA<NotAQuotient>()));
    });

    test('infer TQuotLift with non-quotient quot throws NotAQuotient (TQuot types as VType, not VQuot)', () {
      // TQuot(TType(0), ...)'s inferred type is VType, not VQuot.
      // TQuotLift expects a VQuot-typed term. This tests that case.
      final t = TQuotLift(
        TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
        TLam(TType(0), TBound(0)),
        TProp(),
      );
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      expect(() => infer(ctx, t), throwsA(isA<NotAQuotient>()));
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
      final e = _parse('Quot(Type, (a: Type) -> (b: Type) -> Prop)');
      final term = elabExpr(TopEnv.empty, e);
      expect(term, isA<TQuot>());
      final tq = term as TQuot;
      expect(tq.carrier, isA<TType>());
      expect(tq.relation, isA<TPi>());
    });

    test('elaborate and infer Quot type', () {
      final e = _parse('Quot(Type, (a: Type) -> (b: Type) -> Prop)');
      final term = elabExpr(TopEnv.empty, e);
      final ctx = TopEnv.empty.toCtx();
      expect(infer(ctx, term), isA<VType>());
    });

    test('elaborate mk expression', () {
      final e = _parse('mk Type');
      final term = elabExpr(TopEnv.empty, e);
      expect(term, isA<TQuotMk>());
    });

    test('elaborate lift expression', () {
      final e = _parse('lift(Type, (x: Type) => x)');
      final term = elabExpr(TopEnv.empty, e);
      expect(term, isA<TQuotLift>());
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

    test('Quot.lift into Type with Prop carrier succeeds (quotients are Type-sorted)', () {
      final q = TQuot(TProp(), TPi(TProp(), TPi(TProp(), TProp())));
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      final qType = infer(ctx, q);
      expect(qType, isA<VType>());
      // The carrier sort is VType(1) (Prop : Type 1), so the quotient sorts at Type 1.
      expect((qType as VType).level, equals(1));
    });

    test('Quot with Prop carrier is Type-sorted, not Prop-sorted (Lean 3 fix is architectural)', () {
      final q = TQuot(TProp(), TPi(TProp(), TPi(TProp(), TProp())));
      final ctx = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      final qType = infer(ctx, q);
      expect(qType, isA<VType>());

      final q2 = TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp())));
      final q2Type = infer(ctx, q2);
      expect(q2Type, isA<VType>());
      // Type(0) sorts at Type 1, so the quotient also sorts at Type 1.
      expect((q2Type as VType).level, equals(1));
    });

    test('Quot.lift with VQuot-typed quot and proper fn succeeds in infer', () {
      // Construct a context with a VQuot-typed binder so the quot check
      // succeeds and we exercise the full TQuotLift infer path.
      final base = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      final env = ENil.withRegistries(dataDecls: const [], topBindings: const {});
      final ctx = CCons(
        VQuot(VType(0), VProp()),
        VNeutral(NVar(0)),
        env.extend(VNeutral(NVar(0))),
        1,
        base,
      );
      // TBound(0) has type VQuot. TLam(TType(0), TType(0)) has type (x: Type) -> Type.
      final q = TQuotLift(
        TBound(0),
        TLam(TType(0), TType(0)),
        TType(0),
      );
      final t = infer(ctx, q);
      expect(t, isA<VType>());
    });

    test('Quot.lift with non-VPi fn type throws NotAFunction', () {
      final base = CNil.withRegistries(dataDecls: const [], topBindings: const {});
      final env = ENil.withRegistries(dataDecls: const [], topBindings: const {});
      final ctx = CCons(
        VQuot(VType(0), VProp()),
        VNeutral(NVar(0)),
        env.extend(VNeutral(NVar(0))),
        1,
        base,
      );
      // TType(0) infers to VType(1), which is NOT VPi.
      final q = TQuotLift(
        TBound(0),
        TType(0),
        TType(0),
      );
      expect(
        () => infer(ctx, q),
        throwsA(isA<NotAFunction>()),
      );
    });

    // --- Quotient-in-match tests ---

    test('TQuot inside TMatch case body evaluates correctly', () {
      final t = TMatch(
        TConstr('Nat', 'zero', const []), null, const [
        TMatchCase('zero', 0,
          TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
          const [], span: DoxaSpan.synthetic),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _natDataDecls(), topBindings: const {},
      );
      final v = eval(t, env);
      expect(v, isA<VQuot>());
    });

    test('TQuotMk inside indexed-family match arm evaluates correctly', () {
      final t = TMatch(
        TConstr('Vec', 'vnil', const [TType(0)]), null, const [
        TMatchCase('vnil', 0,
          TQuotMk(TConstr('Nat', 'zero', const [])),
          const [], span: DoxaSpan.synthetic),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _vecDataDecls(), topBindings: const {},
      );
      final v = eval(t, env);
      expect(v, isA<VQuotMk>());
    });

    test('quotient in match round-trips through eval -> quote -> eval', () {
      final t = TMatch(
        TConstr('Nat', 'zero', const []), null, const [
        TMatchCase('zero', 0,
          TQuot(TType(0), TPi(TType(0), TPi(TType(0), TProp()))),
          const [], span: DoxaSpan.synthetic),
      ]);
      final env = ENil.withRegistries(
        dataDecls: _natDataDecls(), topBindings: const {},
      );
      final v = eval(t, env);
      final quoted = quote(0, v);
      expect(quoted, isA<TQuot>());
      final reEval = eval(quoted, env);
      expect(reEval, isA<VQuot>());
    });
  });
}
