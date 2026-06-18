/// Correctness-coverage audit for the inductive-type kernel and elaboration surface.
library;

import 'package:doxa/src/check.dart';
import 'package:doxa/src/elab.dart';
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
  group('SPEC §4.3 + §8.4: VRec × VRec conversion', () {
    test('two stuck VRecs with empty spine are convertible (same decl)', () {
      final env = _elab('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
      final ctx = env.toCtx();
      final v1 = eval(const TRec('Nat'), ctx.env);
      final v2 = eval(const TRec('Nat'), ctx.env);
      expect(conv(0, v1, v2), isA<ConvOk>());
    });

    test('VRec × VRec with pointwise-equal spines convert', () {
      final env = _elab('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
      final ctx = env.toCtx();
      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final rec1 = apply(eval(const TRec('Nat'), ctx.env), motive);
      final rec2 = apply(eval(const TRec('Nat'), ctx.env), motive);
      expect(conv(0, rec1, rec2), isA<ConvOk>());
    });

    test('VRec × VRec with different spine lengths: mismatch', () {
      final env = _elab('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
      final ctx = env.toCtx();
      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final r0 = eval(const TRec('Nat'), ctx.env);
      final r1 = apply(r0, motive);
      expect(conv(0, r0, r1), isA<ConvMismatch>());
    });

    test('VRec × VRec with different dataDecl: mismatch', () {
      final env = _elab('''
data A : Type { ca : A; }
data B : Type { cb : B; }
''');
      final ctx = env.toCtx();
      final rA = eval(const TRec('A'), ctx.env);
      final rB = eval(const TRec('B'), ctx.env);
      expect(conv(0, rA, rB), isA<ConvMismatch>());
    });

    test('VRec × VData of the same name: mismatch (different kinds)', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final rec = eval(const TRec('Nat'), ctx.env);
      const data = VData('Nat', <Value>[]);
      expect(conv(0, rec, data), isA<ConvMismatch>());
    });
  });

  group('SPEC §8.4 + §4.3: TConstr arg-type mismatch fires TypeMismatch', () {
    test('succ applied to zero typechecks: baseline', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val one : Nat = succ zero
''');
      final bindings = <TopBinding>[];
      for (final b in env.bindings) {
        final ctx = TopEnv(bindings, env.dataDecls).toCtx();
        check(ctx, b.term, eval(b.type, ctx.env));
        bindings.add(b);
      }
      expect(bindings.map((b) => b.name), contains('one'));
    });

    test('succ applied to a non-Nat fires TypeMismatch', () {
      // succ expects a Nat; passing `Type` (a sort, not a Nat value)
      // fails the application arg-domain check, throwing TypeMismatch.
      expect(() {
        final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val bad : Nat = succ Type
''');
        final bindings = <TopBinding>[];
        for (final b in env.bindings) {
          final ctx = TopEnv(bindings, env.dataDecls).toCtx();
          check(ctx, b.term, eval(b.type, ctx.env));
          bindings.add(b);
        }
      }, throwsA(isA<TypeMismatch>()));
    });

    test('cons applied with mismatched element type fires TypeMismatch', () {
      // cons expects its second arg to have the parameter type (A).
      // Passing a Nat into a List[Bool] position is a mismatch.
      expect(() {
        final env = _elab('''
data Nat : Type { zero : Nat; }
data Bool : Type { tt : Bool; }
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

val bad : List[Bool] = cons Bool zero (nil Bool)
''');
        final bindings = <TopBinding>[];
        for (final b in env.bindings) {
          final ctx = TopEnv(bindings, env.dataDecls).toCtx();
          check(ctx, b.term, eval(b.type, ctx.env));
          bindings.add(b);
        }
      }, throwsA(isA<TypeMismatch>()));
    });
  });

  group('SPEC §8.2 + §8.4: Prop-sorted data type recursor', () {
    test('data True : Prop { tt : True; } emits True.rec and True.rect', () {
      // Prop-sorted singletons (single-ctor, non-informative args) also
      // auto-emit a .rect large-elim variant with motive target Type 0.
      // `True` qualifies (zero args), so singleton-elim admits.
      final env = _elab('data True : Prop { tt : True; }');
      expect(env.bindings.map((b) => b.name), ['True.rec', 'True.rect']);
    });

    test('True.rec has a well-formed type (infer yields a sort)', () {
      // For a Prop-sorted inductive the motive has codomain Prop; by
      // CIC's impredicativity rule a Pi whose codomain is in Prop is
      // itself in Prop, so True.rec's type is in Prop, not Type n.
      // Either way the inferred type of the recursor must be a sort
      // (VType or VProp).
      final env = _elab('data True : Prop { tt : True; }');
      final decl = env.lookupData('True')!;
      final recType = synthRecursorType(decl);
      final ctx = env.toCtx();
      final t = infer(ctx, recType);
      expect(
        t is VType || t is VProp,
        isTrue,
        reason: 'recursor type must live in a sort',
      );
    });

    test('True.rec binding type-checks', () {
      final env = _elab('data True : Prop { tt : True; }');
      final rec = env.bindings.first;
      final ctx = env.toCtx();
      check(ctx, rec.term, eval(rec.type, ctx.env));
    });
  });

  group('SPEC §8.4: cross-decl ctor name uniqueness', () {
    test('ctor name collision between two data decls rejected', () {
      expect(
        () => _elab('''
data A : Type { shared : A; }
data B : Type { shared : B; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('data name collision with prior val binding rejected', () {
      expect(
        () => _elab('''
val Nat : Type 1 = Type
data Nat : Type { zero : Nat; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('ctor name collision with prior val binding rejected', () {
      expect(
        () => _elab('''
val zero : Type 1 = Type
data Nat : Type { zero : Nat; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });
  });

  group('SPEC §8.4 + §4.3: ι-reduction stays stuck on neutral scrutinee', () {
    test('Nat.rec applied to a neutral Nat yields VRec (no ι-reduction)', () {
      // A recursor saturated with a neutral scrutinee stays a VRec;
      // ι fires only for canonical ctors.
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
      // Neutral scrutinee: a bare NVar representing a free Nat.
      const neutralScrut = VNeutral(NVar(0));
      final rec = eval(const TRec('Nat'), ctx.env);
      var v = apply(rec, motive);
      v = apply(v, pZero);
      v = apply(v, pSucc);
      v = apply(v, neutralScrut);
      // Saturated + neutral scrutinee → stays as VRec.
      expect(v, isA<VRec>());
      final vr = v as VRec;
      expect(vr.spine, hasLength(4));
      expect(vr.spine.last, same(neutralScrut));
    });

    test('quote of stuck VRec recovers TRec + TApp chain', () {
      final env = _elab('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
      final ctx = env.toCtx();
      final motive = eval(
        const TLam(TData('Nat', <Term>[]), TData('Nat', <Term>[])),
        ctx.env,
      );
      final rec = eval(const TRec('Nat'), ctx.env);
      final partial = apply(rec, motive);
      final t = quote(0, partial);
      // Should be TApp(TRec('Nat'), <quoted motive>).
      expect(t, isA<TApp>());
      expect((t as TApp).fn, const TRec('Nat'));
    });
  });

  group('SPEC §8.4: TData as a type lives in its declared sort', () {
    // A `data T : Type` produces a type whose type is Type 0.
    // A `data T : Prop` produces a type whose type is Prop.
    test('Nat : Type 0', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final t = infer(ctx, const TData('Nat', <Term>[]));
      expect(t, isA<VType>());
      expect((t as VType).level, 0);
    });

    test('Big : Type 1', () {
      final env = _elab('data Big : Type 1 { it : Big; }');
      final ctx = env.toCtx();
      final t = infer(ctx, const TData('Big', <Term>[]));
      expect(t, isA<VType>());
      expect((t as VType).level, 1);
    });

    test('P : Prop', () {
      final env = _elab('data P : Prop { it : P; }');
      final ctx = env.toCtx();
      final t = infer(ctx, const TData('P', <Term>[]));
      expect(t, isA<VProp>());
    });
  });

  group('SPEC §4.2: TData / TConstr quote is the identity round-trip', () {
    test('quote(eval(TData("Nat", []))) = TData("Nat", [])', () {
      final env = _elab('data Nat : Type { zero : Nat; }');
      final ctx = env.toCtx();
      final v = eval(const TData('Nat', <Term>[]), ctx.env);
      expect(quote(0, v), const TData('Nat', <Term>[]));
    });

    test('quote(eval(TConstr("Nat", "succ", [zero]))) round-trips', () {
      final env = _elab('data Nat : Type { zero : Nat; succ : Nat -> Nat; }');
      final ctx = env.toCtx();
      final v = eval(
        const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
        ctx.env,
      );
      expect(
        quote(0, v),
        const TConstr('Nat', 'succ', [TConstr('Nat', 'zero', <Term>[])]),
      );
    });
  });
}
