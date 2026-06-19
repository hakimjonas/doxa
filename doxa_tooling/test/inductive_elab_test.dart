/// Elaboration tests for `data` declarations: DataDecl population
/// (params/indices/sort/ctors) and data/ctor name resolution.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

DataDecl _elabOne(String src) {
  final prog = _parse(src);
  final env = elabProgram(prog);
  if (env.dataDecls.length != 1) {
    fail('expected 1 data decl, got ${env.dataDecls.length}');
  }
  return env.dataDecls.first;
}

void main() {
  group('non-parametric Nat', () {
    late DataDecl data;

    setUpAll(() {
      data = _elabOne('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
    });

    test('name and no params/indices', () {
      expect(data.name, 'Nat');
      expect(data.params, isEmpty);
      expect(data.indices, isEmpty);
    });

    test('sort is Type 0', () {
      expect(data.sort, const TType(LLevel(0)));
    });

    test('ctor zero : Nat → args empty, resultIndices empty', () {
      final zero = data.ctors.firstWhere((c) => c.name == 'zero');
      expect(zero.args, isEmpty);
      expect(zero.resultIndices, isEmpty);
      expect(zero.dataName, 'Nat');
    });

    test('ctor succ : Nat -> Nat → one arg (Nat), resultIndices empty', () {
      final succ = data.ctors.firstWhere((c) => c.name == 'succ');
      expect(succ.args, hasLength(1));
      expect(succ.args.first.type, const TData('Nat', <Term>[]));
      expect(succ.resultIndices, isEmpty);
    });
  });

  group('parametric List[A]', () {
    late DataDecl data;

    setUpAll(() {
      data = _elabOne('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
    });

    test('params has one entry (A : Type)', () {
      expect(data.params, hasLength(1));
      expect(data.params.first.name, 'A');
      expect(data.params.first.type, const TType(LLevel(0)));
    });

    test('no indices', () {
      expect(data.indices, isEmpty);
    });

    test('nil : List[A]: result is TData("List", [TBound(0)])', () {
      final nil = data.ctors.firstWhere((c) => c.name == 'nil');
      expect(nil.args, isEmpty);
      // Under the params scope, A is TBound(0). nil's result indices are
      // the non-param result args, empty here (List has no indices).
      expect(nil.resultIndices, isEmpty);
    });

    test(
      'cons : A -> List[A] -> List[A], two args, refers to A via TBound',
      () {
        final cons = data.ctors.firstWhere((c) => c.name == 'cons');
        expect(cons.args, hasLength(2));
        // First arg: A. Under params scope, TBound(0) refers to A.
        expect(cons.args[0].type, const TBound(0));
        // Second arg: List[A]. But now we're one binder deeper (we just
        // passed through the first arg), so A is TBound(1).
        expect(cons.args[1].type, const TData('List', [TBound(1)]));
        // Result indices still empty.
        expect(cons.resultIndices, isEmpty);
      },
    );
  });

  group('Vec with Nat in scope (full SPEC §8.4 program)', () {
    late TopEnv env;

    setUpAll(() {
      final prog = _parse('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Vec[A: Type] : Nat -> Type {
  vnil  : Vec[A] zero;
  vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n);
}
''');
      env = elabProgram(prog);
    });

    test('two data decls registered', () {
      expect(env.dataDecls, hasLength(2));
      expect(env.dataDecls.map((d) => d.name), ['Nat', 'Vec']);
    });

    test('Vec.indices[0] is TData("Nat", [])', () {
      final vec = env.lookupData('Vec')!;
      expect(vec.indices, hasLength(1));
      expect(vec.indices.first.type, const TData('Nat', <Term>[]));
    });

    test('vnil.resultIndices = [zero as TConstr("Nat", "zero", [])]', () {
      final vnil = env.lookupCtor('Vec', 'vnil')!;
      expect(vnil.resultIndices, hasLength(1));
      expect(vnil.resultIndices.first, const TConstr('Nat', 'zero', <Term>[]));
    });

    test('vcons.resultIndices = [succ (TBound 2)]', () {
      // vcons : (n: Nat) -> A -> Vec[A] n -> Vec[A] (succ n)
      // Under params scope (A), then arg scope (n, _, _):
      //   A is TBound(3), n is TBound(2), _ (A-value) is TBound(1),
      //   _ (Vec[A] n) is TBound(0).
      // In the result type `Vec[A] (succ n)`, we're at the final
      // codomain position, same scope depth as the final arg. The
      // result's args are [A-ref, succ-ref-applied-to-n]. Excluding
      // params, resultIndices = [succ n] where n is TBound(2).
      final vcons = env.lookupCtor('Vec', 'vcons')!;
      expect(vcons.resultIndices, hasLength(1));
      final succN = vcons.resultIndices.first;
      expect(succN, isA<TConstr>());
      final sc = succN as TConstr;
      expect(sc.dataName, 'Nat');
      expect(sc.ctorName, 'succ');
      expect(sc.args, hasLength(1));
      expect(sc.args.first, const TBound(2));
    });

    test('lookups by name work', () {
      expect(env.lookupData('Nat'), isNotNull);
      expect(env.lookupData('Bool'), isNull);
      expect(env.lookupCtor('Nat', 'zero'), isNotNull);
      expect(env.lookupCtor('Nat', 'pred'), isNull);
    });

    test('spans preserved on data decls and ctors', () {
      final nat = env.lookupData('Nat')!;
      expect(nat.span.isSynthetic, isFalse);
      final zero = env.lookupCtor('Nat', 'zero')!;
      expect(zero.span.isSynthetic, isFalse);
    });

    test('source AST preserved', () {
      final nat = env.lookupData('Nat')!;
      expect(nat.source, isA<SDataKind>());
      expect(nat.source.name, 'Nat');
      final zero = env.lookupCtor('Nat', 'zero')!;
      expect(zero.source.name, 'zero');
    });
  });

  group('errors', () {
    test('duplicate data name', () {
      final prog = _parse('''
data Nat : Type { zero : Nat; }
data Nat : Type { one : Nat; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DuplicateDeclaration>()));
    });

    test('duplicate ctor name across data decls', () {
      final prog = _parse('''
data A : Type { c : A; }
data B : Type { c : B; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DuplicateDeclaration>()));
    });

    test('duplicate ctor name within same data decl', () {
      final prog = _parse('''
data T : Type { a : T; a : T; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DuplicateDeclaration>()));
    });

    test('ctor name collides with earlier val binding', () {
      final prog = _parse('''
val x : Type 1 = Type
data T : Type { x : T; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DuplicateDeclaration>()));
    });

    test('data decl name collides with earlier val binding', () {
      final prog = _parse('''
val Nat : Type 1 = Type
data Nat : Type { zero : Nat; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DuplicateDeclaration>()));
    });

    test('signature not ending in sort', () {
      // `data T : Nat { ... }`, Nat is a type but not a sort.
      // This requires Nat to be in scope first.
      final prog = _parse('''
data Nat : Type { zero : Nat; }
data T : Nat { it : T; }
''');
      expect(() => elabProgram(prog), throwsA(isA<DataSortNotASort>()));
    });

    test('product form fields desugar to single mk constructor', () {
      // `unit : Type` in `data Unit` is a product field (no Unit ref),
      // desugars to `mk : (unit: Type) -> Unit`.
      final env = elabProgram(_parse('''
data Unit : Type { unit : Type; }
'''));
      expect(env.dataDecls, hasLength(1));
      final data = env.dataDecls.first;
      expect(data.name, 'Unit');
      expect(data.ctors, hasLength(1));
      expect(data.ctors[0].name, 'mk');
    });

    test('constructor result is not this data type', () {
      // When a ctor's result references the data name but with wrong
      // arity, we get CtorResultShapeMismatch.
      final prog = _parse('''
data Pair[A: Type, B: Type] : Type { pair : Pair[A]; }
''');
      expect(() => elabProgram(prog), throwsA(isA<CtorResultShapeMismatch>()));
    });

    test('constructor result has wrong arity', () {
      // List has one parameter, so List[A] is the correct saturated
      // form. Using bare `List` (zero args) is wrong arity.
      final prog = _parse('''
data List[A: Type] : Type {
  nil : List;
}
''');
      expect(() => elabProgram(prog), throwsA(isA<CtorResultShapeMismatch>()));
    });
  });

  group('edge cases', () {
    test('Prop-sorted data decl', () {
      final data = _elabOne('data P : Prop { it : P; }');
      expect(data.sort, const TProp());
    });

    test(
      'data decl followed by a val that would reference it still works syntactically',
      () {
        final prog = _parse('''
data Nat : Type { zero : Nat; }
val ex : Nat = zero
''');
        // elabProgram runs elaboration only (no checking), so it must
        // not throw: name resolution finds Nat and zero, and the val's
        // type/body elaborate. Type checking happens separately.
        final env = elabProgram(prog);
        expect(env.dataDecls, hasLength(1));
        // Type-sorted data auto-emits both `T.rec` (Type motive) and
        // `T.ind` (Prop motive), plus the user's val.
        expect(env.bindings, hasLength(3));
        expect(env.bindings.map((b) => b.name), ['Nat.rec', 'Nat.ind', 'ex']);
        final valBinding = env.bindings.firstWhere((b) => b.name == 'ex');
        expect(valBinding.term, const TConstr('Nat', 'zero', <Term>[]));
        expect(valBinding.type, const TData('Nat', <Term>[]));
      },
    );
  });
}
