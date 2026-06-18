/// Tests for recursor infrastructure (TRec/VRec, synthRecursorType, ι-reduction).
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

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _elab(String src) => elabProgram(_parse(src));

void main() {
  group('TRec basic shape', () {
    test('equality by dataName', () {
      expect(const TRec('Nat'), const TRec('Nat'));
      expect(const TRec('Nat'), isNot(const TRec('List')));
    });

    test('toString includes dataName', () {
      expect(const TRec('Nat').toString(), 'TRec(Nat)');
    });
  });

  group('eval(TRec) yields VRec', () {
    test('TRec(Nat) evaluates to VRec with empty spine', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final v = eval(const TRec('Nat'), ctx.env);
      expect(v, isA<VRec>());
      final vr = v as VRec;
      expect(vr.dataDecl.name, 'Nat');
      expect(vr.spine, isEmpty);
    });

    test('TRec on unknown name is a kernel invariant violation', () {
      expect(
        () => eval(const TRec('Bogus'), const ENil()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('synthRecursorType: Nat', () {
    test('Nat.rec type checks under TopEnv', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final dataDecl = env.lookupData('Nat')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
      // Shape is roughly:
      //   (P: Nat -> Type) -> P zero -> ((n: Nat) -> P n -> P (succ n)) -> (n: Nat) -> P n
      // a Pi chain, so evaluating it yields a VPi.
      final rv = eval(recType, ctx.env);
      expect(rv, isA<VPi>());
    });

    test('Nat.rec arity is 4 (motive, pZero, pSucc, scrutinee)', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final dataDecl = env.lookupData('Nat')!;
      // Arity formula: params + 1 (motive) + ctors + indices + 1
      //              = 0 + 1 + 2 + 0 + 1 = 4.
      final recType = synthRecursorType(dataDecl);
      var count = 0;
      Term t = recType;
      while (t is TPi) {
        count++;
        t = t.codomain;
      }
      expect(count, 4);
    });
  });

  group('synthRecursorType: List', () {
    test('List.rec type checks', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      final dataDecl = env.lookupData('List')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
      final rv = eval(recType, ctx.env);
      expect(rv, isA<VPi>());
    });

    test('List.rec arity is 5 (A, motive, pNil, pCons, scrutinee)', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      final dataDecl = env.lookupData('List')!;
      // 1 + 1 + 2 + 0 + 1 = 5.
      final recType = synthRecursorType(dataDecl);
      var count = 0;
      Term t = recType;
      while (t is TPi) {
        count++;
        t = t.codomain;
      }
      expect(count, 5);
    });
  });

  group('synthRecursorType: Vec (indexed)', () {
    test('Vec.rec type checks', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      final dataDecl = env.lookupData('Vec')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
    });

    test('Vec.rec arity is 6 (A, motive, pVnil, pVcons, index, scrut)', () {
      final env = _elab('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      final dataDecl = env.lookupData('Vec')!;
      // 1 + 1 + 2 + 1 + 1 = 6.
      final recType = synthRecursorType(dataDecl);
      var count = 0;
      Term t = recType;
      while (t is TPi) {
        count++;
        t = t.codomain;
      }
      expect(count, 6);
    });
  });

  group('synthRecursorType: indices whose types reference params', () {
    test('Eq-shaped data (indices of type A where A is a param) '
        'synthesizes a well-typed recursor', () {
      // Regression pin: must not be deleted. The index Pi-wrap once
      // failed to shift TBound refs to outer params, so any inductive
      // whose index types referenced a param (e.g.
      // `data Eq[A] : A -> A -> Prop`) got a synthesized recursor whose
      // indices pointed at the wrong outer binder. Nat/List/Vec avoided
      // the bug because their index types were `Nat` (no param refs).
      //
      // In `A -> A -> Prop` the second occurrence of A is the second
      // index type; in the data decl's scope it is TBound(1) (param A,
      // past one index binder), and on the recursor side the outer-binder
      // offset after wrapping motive + 1 method is what matters.
      final env = _elab('''
data Eq_t[A: Type] : A -> A -> Prop {
  refl_t : (x: A) -> Eq_t[A] x x;
}
''');
      final dataDecl = env.lookupData('Eq_t')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      // Eq_t.rec's type is a Pi chain ending in a Prop-sorted result
      // (the motive's codomain); the impredicative-Prop rule propagates
      // that up, so the rec type itself lives in Prop. The bug made infer
      // throw on bogus TBound refs in the index Pi domains.
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, anyOf(isA<VType>(), isA<VProp>()));
    });
  });

  group('synthRecursorType: ctors with multiple recursive args', () {
    test('Tree.rec (ctor node: Tree -> Tree -> Tree) type-checks', () {
      // Regression pin: must not be deleted. The `node` ctor has TWO
      // self-referential args, so method synthesis must insert TWO IH
      // Pis. An earlier IH-domain builder over-shifted motive/param/arg
      // depths, which was a no-op for single-recursive-arg ctors
      // (Nat.succ, List.cons) but wrong for multi-recursive-arg ctors:
      // matches on Tree triggered an out-of-bounds Env.lookup during
      // conversion of the synthesized recursor type.
      final env = _elab('''
data Tree : Type {
  leaf : Tree;
  node : Tree -> Tree -> Tree;
}
''');
      final dataDecl = env.lookupData('Tree')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
    });

    test('Forest.rec (ctor fcons: Forest -> Forest -> Forest) type-checks', () {
      final env = _elab('''
data Forest : Type {
  fnil  : Forest;
  fcons : Forest -> Forest -> Forest;
}
''');
      final dataDecl = env.lookupData('Forest')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
    });

    test('Triple.rec (ctor t: Triple -> Triple -> Triple -> Triple) '
        'stresses three IHs', () {
      final env = _elab('''
data Triple : Type {
  base : Triple;
  t    : Triple -> Triple -> Triple -> Triple;
}
''');
      final dataDecl = env.lookupData('Triple')!;
      final recType = synthRecursorType(dataDecl);
      final ctx = env.toCtx();
      final typeOfType = infer(ctx, recType);
      expect(typeOfType, isA<VType>());
    });
  });

  group('apply(VRec): spine extension when not saturated', () {
    test('Nat.rec applied to just a motive stays stuck', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final ctx = env.toCtx();
      final rec = eval(const TRec('Nat'), ctx.env);
      // Identity-on-Nat function as a stand-in motive; we only need the
      // spine to extend, not a well-typed motive.
      final motive = eval(
        const TLam(
          TPi(TData('Nat', <Term>[]), TType(1)),
          TData('Nat', <Term>[]),
        ),
        ctx.env,
      );
      final partial = apply(rec, motive);
      expect(partial, isA<VRec>());
      final p = partial as VRec;
      expect(p.spine, hasLength(1));
    });
  });

  group('ι-reduction: Nat.rec on canonical ctor', () {
    test('Nat.rec P pz ps zero reduces to pz', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final ctx = env.toCtx();

      // Non-dependent motive (n: Nat) -> Nat, for simplicity.
      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final pZero = eval(const TConstr('Nat', 'zero', <Term>[]), ctx.env);
      // pSucc: (n: Nat) => (rec: Nat) => succ rec
      final pSucc = eval(
        const TLam(
          TData('Nat', <Term>[]),
          TLam(TData('Nat', <Term>[]), TConstr('Nat', 'succ', [TBound(0)])),
        ),
        ctx.env,
      );
      final scrut = eval(const TConstr('Nat', 'zero', <Term>[]), ctx.env);

      final rec = eval(const TRec('Nat'), ctx.env);
      var v = apply(rec, motive);
      v = apply(v, pZero);
      v = apply(v, pSucc);
      v = apply(v, scrut);
      expect(v, isA<VConstr>());
      final vc = v as VConstr;
      expect(vc.dataName, 'Nat');
      expect(vc.ctorName, 'zero');
    });

    test('Nat.rec P pz pSucc (succ (succ zero)) reduces via two ι-steps', () {
      // pSucc = (n) => (rec) => succ rec makes the recursor compute the
      // identity on the scrutinee, so succ (succ zero) maps back to itself.
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final ctx = env.toCtx();

      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final pZero = eval(const TConstr('Nat', 'zero', <Term>[]), ctx.env);
      final pSucc = eval(
        const TLam(
          TData('Nat', <Term>[]),
          TLam(TData('Nat', <Term>[]), TConstr('Nat', 'succ', [TBound(0)])),
        ),
        ctx.env,
      );

      final succSuccZero = eval(
        const TConstr('Nat', 'succ', [
          TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        ]),
        ctx.env,
      );

      final rec = eval(const TRec('Nat'), ctx.env);
      var v = apply(rec, motive);
      v = apply(v, pZero);
      v = apply(v, pSucc);
      v = apply(v, succSuccZero);

      expect(v, isA<VConstr>());
      var vc = v as VConstr;
      expect(vc.ctorName, 'succ');
      expect(vc.args, hasLength(1));
      expect(vc.args[0], isA<VConstr>());
      vc = vc.args[0] as VConstr;
      expect(vc.ctorName, 'succ');
      expect(vc.args, hasLength(1));
      expect(vc.args[0], isA<VConstr>());
      expect((vc.args[0] as VConstr).ctorName, 'zero');
    });
  });

  group('quote(VRec) round-trips', () {
    test('bare Nat.rec quotes to TRec(Nat)', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final rec = eval(const TRec('Nat'), ctx.env);
      final t = quote(0, rec);
      expect(t, const TRec('Nat'));
    });

    test('partially-applied Nat.rec quotes to TApp chain', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final ctx = env.toCtx();
      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final rec = eval(const TRec('Nat'), ctx.env);
      final partial = apply(rec, motive);
      final t = quote(0, partial);
      expect(t, isA<TApp>());
      final ta = t as TApp;
      expect(ta.fn, const TRec('Nat'));
    });
  });

  group('`T.rec` bindings auto-emitted from `data` decls', () {
    test('data Nat emits a Nat.rec binding', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      // Type-sorted data auto-emits both the recursor and a Prop-motive
      // induction principle, so .rec and .ind both appear.
      expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind']);
    });

    test('Nat.rec binding has correct term and type', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final rec = env.bindings.firstWhere((b) => b.name == 'Nat.rec');
      expect(rec.term, const TRec('Nat'));
      // Type matches synthRecursorType (structural, since the two
      // terms are built by the same code path).
      final dataDecl = env.lookupData('Nat')!;
      expect(rec.type, synthRecursorType(dataDecl));
    });

    test('Nat.rec binding type-checks through the CLI-style pipeline', () {
      // Mirrors the CLI: elab + per-binding check.
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      final rec = env.bindings.firstWhere((b) => b.name == 'Nat.rec');
      final ctx = env.toCtx();
      check(ctx, rec.term, eval(rec.type, ctx.env));
    });

    test('data List emits List.rec and List.ind', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      expect(env.bindings.map((b) => b.name), ['List.rec', 'List.ind']);
      final rec = env.bindings.first;
      expect(rec.term, const TRec('List'));
      final ctx = env.toCtx();
      check(ctx, rec.term, eval(rec.type, ctx.env));
    });

    test('data Vec emits Vec.rec + .ind alongside Nat.rec + .ind', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      expect(env.bindings.map((b) => b.name), [
        'Nat.rec',
        'Nat.ind',
        'Vec.rec',
        'Vec.ind',
      ]);
      final ctx = env.toCtx();
      for (final b in env.bindings) {
        check(ctx, b.term, eval(b.type, ctx.env));
      }
    });

    test('span on the T.rec binding matches the data decl span', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final rec = env.bindings.first;
      final dataDecl = env.lookupData('Nat')!;
      expect(rec.span, dataDecl.span);
    });
  });
}
