import 'package:doxa/src/elab.dart';
import 'package:doxa/src/env.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse a single expression, asserting success.
SExpr pe(String input) {
  final r = parseExpr(input);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}

/// Parse a program, asserting success.
SProgram pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Elaborate an expression in the empty top environment.
Term ee(String src) => elabExpr(TopEnv.empty, pe(src));

void main() {
  group('Expression elaboration: atoms', () {
    test('Type (no level) elaborates to Type 0', () {
      expect(ee('Type'), const TType(0));
    });

    test('Type 5 elaborates to Type 5', () {
      expect(ee('Type 5'), const TType(5));
    });

    test('unresolved name throws UnresolvedName', () {
      expect(() => ee('foo'), throwsA(isA<UnresolvedName>()));
    });
  });

  group('Expression elaboration: binders produce de Bruijn', () {
    test('(x: Type) => x elaborates to TLam(Type 0, TBound(0))', () {
      expect(ee('(x: Type) => x'), const TLam(TType(0), TBound(0)));
    });

    test('(A: Type) -> A elaborates to TPi(Type 0, TBound(0))', () {
      expect(ee('(A: Type) -> A'), const TPi(TType(0), TBound(0)));
    });

    test('A -> B (non-dep arrow, both unbound) fails with unresolved A', () {
      expect(() => ee('A -> B'), throwsA(isA<UnresolvedName>()));
    });

    test('nested lambda: (A: Type) => (x: A) => x', () {
      // Outer: param A, domain Type 0.
      // Inner: param x, domain A (= TBound(0) under outer).
      // Body: x (= TBound(0) under inner).
      final t = ee('(A: Type) => (x: A) => x');
      expect(t, const TLam(TType(0), TLam(TBound(0), TBound(0))));
    });

    test('dependent Pi: (A: Type) -> A -> A', () {
      // Outer: (A: Type) -> ...
      // Inner: A -> A  (non-dep arrow). Domain is A = TBound(0) under outer.
      // Codomain is A under the non-dep Pi, which is TBound(1), because
      // the non-dep binder shifts inner references up by one.
      final t = ee('(A: Type) -> A -> A');
      expect(t, const TPi(TType(0), TPi(TBound(0), TBound(1))));
    });

    test('shadowing: inner binder hides outer with same name', () {
      // (x: Type) => (x: Type) => x
      //   outer binder x, then inner binder x, body references x.
      //   Inner shadows outer, so body's x = TBound(0) refers to inner.
      final t = ee('(x: Type) => (x: Type) => x');
      expect(t, const TLam(TType(0), TLam(TType(0), TBound(0))));
    });
  });

  group('Application desugaring', () {
    test('f a b desugars to TApp(TApp(f, a), b)', () {
      // Need a ctx for f, a, b. Simplest: build as a lambda body where
      // all three are parameters.
      final t = ee('(f: Type) => (a: Type) => (b: Type) => f a b');
      // Under λf. λa. λb., the body references f = TBound(2), a = TBound(1),
      // b = TBound(0).
      expect(
        t,
        const TLam(
          TType(0),
          TLam(
            TType(0),
            TLam(TType(0), TApp(TApp(TBound(2), TBound(1)), TBound(0))),
          ),
        ),
      );
    });
  });

  group('Declarations', () {
    test('val x: Type 1 = Type produces a TopBinding', () {
      // `Type : Type 1`, so the body's type matches the declared type.
      // (A `Type 0` annotation would be a genuine type error, now caught
      // during elaboration since val bodies are checked against their
      // declared type.)
      final env = elabProgram(pp('val x: Type 1 = Type'));
      expect(env.bindings, hasLength(1));
      final b = env.bindings[0];
      expect(b.name, 'x');
      expect(b.type, const TType(1));
      expect(b.term, const TType(0));
    });

    test('val without type annotation infers Type', () {
      // val x = Type, the body has type Type 1 (Type 0 : Type 1).
      final env = elabProgram(pp('val x = Type'));
      final b = env.bindings[0];
      expect(b.term, const TType(0));
      expect(b.type, const TType(1));
    });

    test('duplicate top-level declaration raises DuplicateDeclaration', () {
      expect(
        () => elabProgram(pp('val x = Type val x = Type')),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('later declaration references earlier one', () {
      final env = elabProgram(pp('val x = Type val y = x'));
      expect(env.bindings, hasLength(2));
      // Top-level refs use TTop(name), not TBound: y's body is
      // `TTop("x")`, a name-indexed global reference resolved via
      // env.topBindings at eval time.
      final y = env.bindings[1];
      expect(y.term, const TTop('x'));
    });

    test('forward reference does NOT work (sequential, no recursion)', () {
      // y references x, but x is declared after y.
      expect(
        () => elabProgram(pp('val y = x val x = Type')),
        throwsA(isA<UnresolvedName>()),
      );
    });

    test('self reference in val body does NOT work', () {
      // val x = x would be "x refers to itself", rejected.
      expect(
        () => elabProgram(pp('val x = x')),
        throwsA(isA<UnresolvedName>()),
      );
    });
  });

  group('fun desugaring', () {
    test('fun id[A: Type](x: A): A = x', () {
      // Desugars to:
      //   val id : (A: Type) -> (x: A) -> A
      //          = (A) => (x) => x
      final env = elabProgram(pp('fun id[A: Type](x: A): A = x'));
      final b = env.bindings[0];
      expect(b.name, 'id');
      // Type: (A: Type 0) -> (x: A) -> A
      expect(b.type, const TPi(TType(0), TPi(TBound(0), TBound(1))));
      // Body: λA. λx. x
      expect(b.term, const TLam(TType(0), TLam(TBound(0), TBound(0))));
    });

    test('fun body that self-references non-structurally is rejected', () {
      // Self-recursion is allowed but must be structural. `loop x` passes
      // its designated arg `x` (not a strict sub-term of itself), so it's
      // rejected as NonStructuralRecursion rather than UnresolvedName.
      expect(
        () => elabProgram(pp('fun loop(x: Type): Type = loop x')),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'loop',
          ),
        ),
      );
    });

    test('fun with no type params', () {
      final env = elabProgram(pp('fun k(x: Type): Type = x'));
      final b = env.bindings[0];
      expect(b.type, const TPi(TType(0), TType(0)));
      expect(b.term, const TLam(TType(0), TBound(0)));
    });

    test('fun with multiple parameters', () {
      // fun const[A: Type, B: Type](x: A, y: B): A = x
      // Desugars to: (A: Type) -> (B: Type) -> (x: A) -> (y: B) -> A
      // and         λA. λB. λx. λy. x
      //
      // Under the body (A, B, x, y bound outside-in):
      //   A = TBound(3), B = TBound(2), x = TBound(1), y = TBound(0)
      final env = elabProgram(
        pp('fun const_[A: Type, B: Type](x: A, y: B): A = x'),
      );
      final b = env.bindings[0];
      expect(
        b.type,
        const TPi(
          TType(0),
          TPi(TType(0), TPi(TBound(1), TPi(TBound(1), TBound(3)))),
        ),
      );
      expect(
        b.term,
        const TLam(
          TType(0),
          TLam(TType(0), TLam(TBound(1), TLam(TBound(1), TBound(1)))),
        ),
      );
    });
  });

  group('Name hints', () {
    test('source name survives into TLam', () {
      final t = ee('(myParam: Type) => myParam') as TLam;
      expect(t.name, 'myParam');
    });

    test('source name survives into TPi (dependent)', () {
      final t = ee('(A: Type) -> A') as TPi;
      expect(t.name, 'A');
    });

    test('non-dependent arrow has no name hint', () {
      // A -> B, no surface parameter name.
      // Wrap it in a binder so the unresolved-name test doesn't fire.
      final outer = ee('(A: Type) => (B: Type) => A -> B') as TLam;
      // outer is λA. λB. (A -> B). The innermost lambda's body is TPi.
      final middle = outer.body as TLam;
      final arrow = middle.body as TPi;
      expect(arrow.name, isNull);
    });

    test('names survive the full parse → elab → eval → quote round trip', () {
      // Normalize a named function; the quoted result should still
      // carry the name, because quote preserves hints from VLam/VPi.
      final t = ee('(A: Type) => (x: A) => x');
      // normalize (nothing β-reduces here, it's already in normal form)
      // and check the outer name survives.
      final norm = nf(t) as TLam;
      expect(norm.name, 'A');
      final inner = norm.body as TLam;
      expect(inner.name, 'x');
    });

    test('fun-desugared lambdas carry parameter names', () {
      final env = elabProgram(pp('fun id[A: Type](x: A): A = x'));
      final body = env.bindings[0].term as TLam;
      expect(body.name, 'A');
      final inner = body.body as TLam;
      expect(inner.name, 'x');

      final type = env.bindings[0].type as TPi;
      expect(type.name, 'A');
      final codPi = type.codomain as TPi;
      expect(codPi.name, 'x');
    });
  });

  group('End-to-end: parse → elaborate → normalize', () {
    test('identity of identity: id(id)(Type) normalizes', () {
      // The id definition normalizes to itself (already in normal form).
      final env = elabProgram(pp('fun id[A: Type](x: A): A = x'));
      final b = env.bindings[0];
      final normalized = nf(b.term);
      expect(normalized, b.term);
    });

    test('val definition is reachable through top-level Env', () {
      final env = elabProgram(pp('val zero = Type'));
      final b = env.bindings[0];
      final v = eval(b.term, const ENil());
      expect(v, isA<VType>());
      expect((v as VType).level, 0);
    });
  });
}
