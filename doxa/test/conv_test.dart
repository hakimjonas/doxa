import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Evaluate [term] in the empty env and compare it at level 0 with [other].
///
/// Most tests want to compare kernel terms, not hand-rolled values. This
/// helper keeps the test bodies short.
ConvResult convTerms(Term a, Term b) =>
    conv(0, eval(a, const ENil()), eval(b, const ENil()));

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

void main() {
  group('Universe equality (strict, non-cumulative)', () {
    test('Type 0 converts with Type 0', () {
      expect(
        convTerms(const TType(LLevel(0)), const TType(LLevel(0))),
        isA<ConvOk>(),
      );
    });

    test('Type 3 converts with Type 3', () {
      expect(
        convTerms(const TType(LLevel(3)), const TType(LLevel(3))),
        isA<ConvOk>(),
      );
    });

    test('Type 0 does NOT convert with Type 1', () {
      final r = convTerms(const TType(LLevel(0)), const TType(LLevel(1)));
      expect(r, isA<ConvMismatch>());
      final m = r as ConvMismatch;
      expect((m.got as VType).level, const LLevel(0));
      expect((m.expected as VType).level, const LLevel(1));
    });

    test('Type 5 does NOT convert with Type 4 (either direction)', () {
      expect(
        convTerms(const TType(LLevel(5)), const TType(LLevel(4))),
        isA<ConvMismatch>(),
      );
      expect(
        convTerms(const TType(LLevel(4)), const TType(LLevel(5))),
        isA<ConvMismatch>(),
      );
    });
  });

  group('α-equivalence', () {
    test('two identity lambdas are α-equivalent', () {
      // De Bruijn kernel terms carry no surface names, so these are
      // identical regardless of how they were originally written.
      const id1 = TLam(TType(LLevel(0)), TBound(0));
      const id2 = TLam(TType(LLevel(0)), TBound(0));
      expect(convTerms(id1, id2), isA<ConvOk>());
    });

    test('constant function (λ_. c) with distinct constants differ', () {
      const f1 = TLam(TType(LLevel(0)), TType(LLevel(1)));
      const f2 = TLam(TType(LLevel(0)), TType(LLevel(2)));
      expect(convTerms(f1, f2), isA<ConvMismatch>());
    });
  });

  group('β-equivalence', () {
    test('(λx. x) y reduces to y before comparison', () {
      const reduced = TType(LLevel(3));
      const lhs = TApp(TLam(TType(LLevel(0)), TBound(0)), TType(LLevel(3)));
      expect(convTerms(lhs, reduced), isA<ConvOk>());
    });

    test('(λx. λy. x) a b ≡ a', () {
      const app = TApp(
        TApp(
          TLam(TType(LLevel(0)), TLam(TType(LLevel(0)), TBound(1))),
          TType(LLevel(5)),
        ),
        TType(LLevel(7)),
      );
      const a = TType(LLevel(5));
      expect(convTerms(app, a), isA<ConvOk>());
    });
  });

  group('η-equivalence', () {
    test('(λx. f(x)) ≡ f when f is free', () {
      // lhs is λx. f(x) under an env where f (NVar(0)) is at index 0;
      // rhs is f itself. Compare at level 1 so NVar(0) is outer.
      final envWithF = const ENil().extend(const VNeutral(NVar(0)));
      final lhsVal = eval(
        const TLam(TType(LLevel(0)), TApp(TBound(1), TBound(0))),
        envWithF,
      );
      const rhsVal = VNeutral(NVar(0));
      expect(conv(1, lhsVal, rhsVal), isA<ConvOk>());
    });

    test('η on the right: f ≡ (λx. f(x))', () {
      final envWithF = const ENil().extend(const VNeutral(NVar(0)));
      final rhsVal = eval(
        const TLam(TType(LLevel(0)), TApp(TBound(1), TBound(0))),
        envWithF,
      );
      const lhsVal = VNeutral(NVar(0));
      expect(conv(1, lhsVal, rhsVal), isA<ConvOk>());
    });

    test('(λx. g(x)) ≢ f when f and g are different neutrals', () {
      final envWithFg = const ENil()
          .extend(const VNeutral(NVar(0))) // f at index 0, level 0
          .extend(const VNeutral(NVar(1))); // g at index 0 now, level 1
      // λx. g(x), g is at index 1 in the new inner env after one more binder.
      final lhs = eval(
        const TLam(TType(LLevel(0)), TApp(TBound(1), TBound(0))),
        envWithFg,
      );
      const rhs = VNeutral(NVar(0)); // f
      expect(conv(2, lhs, rhs), isA<ConvMismatch>());
    });
  });

  group('Pi equivalence', () {
    test('equal non-dependent arrows', () {
      const a = TPi(TType(LLevel(0)), TType(LLevel(0)));
      const b = TPi(TType(LLevel(0)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvOk>());
    });

    test('different domains → mismatch', () {
      const a = TPi(TType(LLevel(0)), TType(LLevel(0)));
      const b = TPi(TType(LLevel(1)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });

    test('different codomains → mismatch', () {
      const a = TPi(TType(LLevel(0)), TType(LLevel(0)));
      const b = TPi(TType(LLevel(0)), TType(LLevel(1)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });

    test('dependent Pi: (A: Type) -> A converts with itself', () {
      const a = TPi(TType(LLevel(0)), TBound(0));
      const b = TPi(TType(LLevel(0)), TBound(0));
      expect(convTerms(a, b), isA<ConvOk>());
    });
  });

  group('Neutral spine comparison', () {
    test('same head, same single argument', () {
      const a = VNeutral(NApp(NVar(0), VType(LLevel(1))));
      const b = VNeutral(NApp(NVar(0), VType(LLevel(1))));
      expect(conv(1, a, b), isA<ConvOk>());
    });

    test('same head, different single argument → mismatch', () {
      const a = VNeutral(NApp(NVar(0), VType(LLevel(1))));
      const b = VNeutral(NApp(NVar(0), VType(LLevel(2))));
      final r = conv(1, a, b);
      expect(r, isA<ConvMismatch>());
      final m = r as ConvMismatch;
      expect((m.got as VType).level, const LLevel(1));
      expect((m.expected as VType).level, const LLevel(2));
    });

    test('different heads → mismatch', () {
      const a = VNeutral(NApp(NVar(0), VType(LLevel(1))));
      const b = VNeutral(NApp(NVar(1), VType(LLevel(1))));
      expect(conv(2, a, b), isA<ConvMismatch>());
    });

    test('different spine lengths → mismatch', () {
      const a = VNeutral(NVar(0));
      const b = VNeutral(NApp(NVar(0), VType(LLevel(1))));
      expect(conv(1, a, b), isA<ConvMismatch>());
    });

    test('two-arg spines compare arg-by-arg; first differing arg reported', () {
      // f(Type 1)(Type 5) vs f(Type 1)(Type 6): only the 5-vs-6 arg differs.
      const a = VNeutral(
        NApp(NApp(NVar(0), VType(LLevel(1))), VType(LLevel(5))),
      );
      const b = VNeutral(
        NApp(NApp(NVar(0), VType(LLevel(1))), VType(LLevel(6))),
      );
      final r = conv(1, a, b);
      expect(r, isA<ConvMismatch>());
      final m = r as ConvMismatch;
      expect((m.got as VType).level, const LLevel(5));
      expect((m.expected as VType).level, const LLevel(6));
    });

    test('two-arg spines: first arg differs, second not reached', () {
      // f(Type 1)(Type 5) vs f(Type 9)(Type 5): the 1-vs-9 mismatch fires
      // before the matching Type 5 args are compared.
      const a = VNeutral(
        NApp(NApp(NVar(0), VType(LLevel(1))), VType(LLevel(5))),
      );
      const b = VNeutral(
        NApp(NApp(NVar(0), VType(LLevel(9))), VType(LLevel(5))),
      );
      final r = conv(1, a, b);
      expect(r, isA<ConvMismatch>());
      final m = r as ConvMismatch;
      expect((m.got as VType).level, const LLevel(1));
      expect((m.expected as VType).level, const LLevel(9));
    });
  });

  group('Cross-shape mismatches', () {
    test('Type vs Pi → mismatch', () {
      const a = TType(LLevel(0));
      const b = TPi(TType(LLevel(0)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });

    test('Pi vs Lam → mismatch', () {
      const a = TPi(TType(LLevel(0)), TType(LLevel(0)));
      const b = TLam(TType(LLevel(0)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });

    test('Type vs Lam → mismatch', () {
      const a = TType(LLevel(0));
      const b = TLam(TType(LLevel(0)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });
  });

  group('Lambda domain annotations are NOT compared', () {
    test('(λ_: Type 0. Type 0) ≡ (λ_: Type 7. Type 0) since body matches', () {
      // The domain annotation is not part of equivalence; both bodies
      // return Type 0, so the lambdas are equal despite Type 0 vs Type 7.
      const a = TLam(TType(LLevel(0)), TType(LLevel(0)));
      const b = TLam(TType(LLevel(7)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvOk>());
    });

    test('differently-annotated identity functions are equivalent', () {
      // Applied to a fresh neutral both reduce to the same neutral, so
      // they convert despite the Type 0 vs Type 1 annotation difference.
      const a = TLam(TType(LLevel(0)), TBound(0));
      const b = TLam(TType(LLevel(1)), TBound(0));
      expect(convTerms(a, b), isA<ConvOk>());
    });
  });

  group('Deep mismatch reporting', () {
    test('mismatch under two Pi layers points at the innermost diff', () {
      const a = TPi(TPi(TType(LLevel(0)), TType(LLevel(0))), TType(LLevel(0)));
      const b = TPi(TPi(TType(LLevel(0)), TType(LLevel(1))), TType(LLevel(0)));
      final r = convTerms(a, b);
      expect(r, isA<ConvMismatch>());
      final m = r as ConvMismatch;
      expect((m.got as VType).level, const LLevel(0));
      expect((m.expected as VType).level, const LLevel(1));
    });

    test('dependent Pi mismatch in codomain', () {
      // Codomains differ (TBound(0) vs TType(LLevel(0))); opening at level 1 makes
      // the lhs body a neutral and the rhs Type 0, which do not convert.
      const a = TPi(TType(LLevel(0)), TBound(0));
      const b = TPi(TType(LLevel(0)), TType(LLevel(0)));
      expect(convTerms(a, b), isA<ConvMismatch>());
    });
  });

  group('Stack safety of conv', () {
    test('comparing deeply nested equal Pi structures does not blow stack', () {
      const depth = 10000;
      Term t = const TType(LLevel(0));
      for (var i = 0; i < depth; i++) {
        t = TPi(const TType(LLevel(0)), t);
      }
      expect(convTerms(t, t), isA<ConvOk>());
    });

    test('long equal neutral spines do not blow stack', () {
      const depth = 10000;
      // Build f(Type 0)(Type 0)...(Type 0) as a value directly.
      Neutral n = const NVar(0);
      for (var i = 0; i < depth; i++) {
        n = NApp(n, const VType(LLevel(0)));
      }
      final v = VNeutral(n);
      expect(conv(1, v, v), isA<ConvOk>());
    });
  });

  group('Constructor Injectivity', () {
    test('same constructor, same stuck argument', () {
      const a = VConstr('Nat', 'succ', [VNeutral(NVar(0))]);
      const b = VConstr('Nat', 'succ', [VNeutral(NVar(0))]);
      expect(conv(1, a, b), isA<ConvOk>());
    });

    test('different constructors', () {
      const a = VConstr('Nat', 'zero', []);
      const b = VConstr('Nat', 'succ', []);
      expect(conv(0, a, b), isA<ConvMismatch>());
    });

    test('same constructor, differing arguments', () {
      const a = VConstr('Nat', 'succ', [VNeutral(NVar(0))]);
      const b = VConstr('Nat', 'succ', [VNeutral(NVar(1))]);
      expect(conv(1, a, b), isA<ConvMismatch>());
    });

    test('Type-sorted VConstr values mismatch: zero vs succ zero', () {
      final env = elabProgram(
        _parse('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
'''),
      );
      final ctx = env.toCtx();
      Value val(String src) {
        final t = elabExpr(env, _parseExpr(src));
        return eval(t, ctx.env);
      }

      final v1 = val('zero');
      final v2 = val('succ zero');
      expect(conv(0, v1, v2, dataDecls: env.dataDecls), isA<ConvMismatch>());
    });

    test('succ_injective propositional proof type-checks', () {
      const src = '''
data Eq[A: Type] : A -> A -> Prop {
  refl : (x: A) -> Eq[A] x x;
}

data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ k => k
}

val succ_injective : (a: Nat) -> (b: Nat) -> Eq[Nat] (succ a) (succ b) -> Eq[Nat] a b =
  (a: Nat) => (b: Nat) => (h: Eq[Nat] (succ a) (succ b)) =>
    Eq.rec Nat
      ((x: Nat) => (y: Nat) => (p: Eq[Nat] x y) => Eq[Nat] (pred x) (pred y))
      (succ a) (succ b)
      ((z: Nat) => refl (pred z))
      h
''';
      final prog = _parse(src);
      var bindings = const <TopBinding>[];
      var dataDecls = const <DataDecl>[];
      for (final decl in prog.decls) {
        final produced = elabDecl(TopEnv(bindings, dataDecls), decl);
        dataDecls = [...dataDecls, ...produced.dataDecls];
        bindings = [
          ...bindings,
          ...checkDeclResult(TopEnv(bindings, dataDecls), produced),
        ];
      }
    });
  });

  group('Prop definitional proof irrelevance', () {
    // Shared prelude: a Prop-sorted data with two distinct proofs. This is
    // the minimal shape that exercises irrelevance; without two distinct
    // ctors, structural conv would trivially admit.
    final propEnv = elabProgram(
      _parse('''
data P : Prop {
  p1 : P;
  p2 : P;
}
data N : Type {
  n1 : N;
  n2 : N;
}
'''),
    );

    Value valOf(String src) {
      final ctx = propEnv.toCtx();
      final t = elabExpr(propEnv, _parseExpr(src));
      return eval(t, ctx.env);
    }

    test('two distinct ctors of a Prop-sorted type: conv WITHOUT dataDecls '
        'returns Mismatch', () {
      // Baseline: the bare conv API (no registry) preserves structural
      // semantics, so p1 vs p2 is a ctor-name mismatch. Guards the
      // additive-only contract for irrelevance.
      final v1 = valOf('p1');
      final v2 = valOf('p2');
      expect(conv(0, v1, v2), isA<ConvMismatch>());
    });

    test('two distinct ctors of a Prop-sorted type: conv WITH dataDecls '
        'admits by irrelevance', () {
      // p1 and p2 are different ctors of P : Prop, so structural conv
      // fails. With the registry threaded, irrelevance fires: both values
      // have a Prop-sorted type, so they are definitionally equal.
      final v1 = valOf('p1');
      final v2 = valOf('p2');
      final r = conv(0, v1, v2, dataDecls: propEnv.dataDecls);
      expect(r, isA<ConvOk>());
    });

    test('Type-sorted values with distinct ctors still mismatch even with '
        'dataDecls (irrelevance does not over-reach)', () {
      // N : Type, so n1 and n2 live in a Type-sorted inductive where
      // irrelevance must NOT fire. Guards against over-admission.
      final v1 = valOf('n1');
      final v2 = valOf('n2');
      final r = conv(0, v1, v2, dataDecls: propEnv.dataDecls);
      expect(r, isA<ConvMismatch>());
    });

    test('propositions themselves (P : Prop vs N : Type) do not convert '
        'under irrelevance', () {
      // If a value's type is Prop itself, the value IS a proposition (not a
      // proof of one), so irrelevance must not fire. P : Prop and N : Type
      // stay distinct regardless of the registry.
      final p = valOf('P');
      final n = valOf('N');
      final r = conv(0, p, n, dataDecls: propEnv.dataDecls);
      expect(r, isA<ConvMismatch>());
    });

    test('irrelevance fires after eta-opening two Prop-returning lambdas', () {
      // (n: N) => p1 vs (n: N) => p2: eta-opening applies both sides to a
      // fresh neutral, and irrelevance fires on p1 vs p2 at the opened-body
      // layer, not at the lambda layer.
      final env = propEnv;
      final ctx = env.toCtx();
      Value v(String src) => eval(elabExpr(env, _parseExpr(src)), ctx.env);
      final a = v('(n: N) => p1');
      final b = v('(n: N) => p2');
      expect(conv(0, a, b), isA<ConvMismatch>());
      expect(conv(0, a, b, dataDecls: env.dataDecls), isA<ConvOk>());
    });

    test('irrelevance fires when Prop mismatch is nested inside a compound '
        'value', () {
      // wrap p1 p1 vs wrap p2 p2: structural conv recurses into the args,
      // where the inner conv on the p1-vs-p2 pair fires irrelevance and the
      // outer VConstr recursion then completes Ok. The shape that matters
      // for real proof composition.
      final env = elabProgram(
        _parse('''
data P : Prop {
  p1 : P;
  p2 : P;
}

data Wrap : Prop {
  wrap : P -> P -> Wrap;
}
'''),
      );
      final ctx = env.toCtx();
      Value v(String src) => eval(elabExpr(env, _parseExpr(src)), ctx.env);
      final a = v('wrap p1 p1');
      final b = v('wrap p2 p2');
      expect(conv(0, a, b), isA<ConvMismatch>());
      expect(conv(0, a, b, dataDecls: env.dataDecls), isA<ConvOk>());
    });
  });
}

SExpr _parseExpr(String src) {
  final r = parseExpr(src);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}
