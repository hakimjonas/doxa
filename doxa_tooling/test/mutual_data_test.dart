/// Mutual `data` blocks.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _elab(String src) => elabProgram(_parseProg(src));

/// Elaborate + per-binding check, CLI-style.
TopEnv _elabAndCheck(String src) {
  final env = _elab(src);
  final acc = <TopBinding>[];
  for (final b in env.bindings) {
    final runningEnv = TopEnv(acc, env.dataDecls);
    final ctx = runningEnv.toCtx();
    check(ctx, b.term, eval(b.type, ctx.env));
    acc.add(b);
  }
  return env;
}

void main() {
  group('parser: `data ... and data ...` produces SDataBlockKind', () {
    test('single data (no and) still parses as SDataKind', () {
      final p = _parseProg('data Nat : Type { zero : Nat; }');
      expect(p.decls, hasLength(1));
      expect(p.decls.single.kind, isA<SDataKind>());
    });

    test('two data decls chained with `and data` parse as SDataBlockKind', () {
      final p = _parseProg('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
''');
      expect(p.decls, hasLength(1));
      expect(p.decls.single.kind, isA<SDataBlockKind>());
      final block = p.decls.single.kind as SDataBlockKind;
      expect(block.members.map((m) => m.data.name), ['Even', 'Odd']);
    });

    test('three data decls chain correctly', () {
      final p = _parseProg('''
data A : Type { ca : A; }
and data B : Type { cb : B; }
and data C : Type { cc : C; }
''');
      final block = p.decls.single.kind as SDataBlockKind;
      expect(block.members.map((m) => m.data.name), ['A', 'B', 'C']);
    });
  });

  group('elaboration: mutual data registers all + emits recursors', () {
    test('Even/Odd: both DataDecls registered with cross-references', () {
      final env = _elab('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
''');
      expect(env.dataDecls.map((d) => d.name), ['Even', 'Odd']);
      // esucc's arg type mentions Odd: elaboration must resolve the
      // sibling name, since both are in scope across the block.
      final even = env.lookupData('Even')!;
      final esucc = even.ctors.firstWhere((c) => c.name == 'esucc');
      expect(esucc.args.single.type, const TData('Odd', <Term>[]));
      final odd = env.lookupData('Odd')!;
      final osucc = odd.ctors.firstWhere((c) => c.name == 'osucc');
      expect(osucc.args.single.type, const TData('Even', <Term>[]));
    });

    test('both recursors auto-emitted as T.rec bindings', () {
      final env = _elab('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
''');
      // Type-sorted data auto-emits `.ind` (a Prop-motive eliminator)
      // alongside `.rec` (the data's own sort motive).
      expect(env.bindings.map((b) => b.name), [
        'Even.rec',
        'Even.ind',
        'Odd.rec',
        'Odd.ind',
      ]);
    });

    test('both recursors type-check through the CLI pipeline', () {
      final env = _elabAndCheck('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
''');
      expect(env.bindings, hasLength(4));
    });
  });

  group('positivity: mutual block enforces block-wide discipline', () {
    test('Even.esucc : Odd -> Even (positive) accepted', () {
      _elabAndCheck('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
''');
    });

    test('Even.bad : (Odd -> Even) -> Even rejected (Odd in negative pos)', () {
      expect(
        () => _elab('''
data Even : Type {
  ezero : Even;
  bad : (Odd -> Even) -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
'''),
        throwsA(
          isA<PositivityViolation>()
              .having((e) => e.dataName, 'dataName', 'Even')
              .having((e) => e.ctorName, 'ctorName', 'bad'),
        ),
      );
    });

    test('Odd.bad : (Even -> Odd) -> Odd rejected too', () {
      expect(
        () => _elab('''
data Even : Type {
  ezero : Even;
}
and data Odd : Type {
  bad : (Even -> Odd) -> Odd;
}
'''),
        throwsA(
          isA<PositivityViolation>()
              .having((e) => e.dataName, 'dataName', 'Odd')
              .having((e) => e.ctorName, 'ctorName', 'bad'),
        ),
      );
    });

    test('Self-negative-reference in a block member is still rejected', () {
      expect(
        () => _elab('''
data Even : Type {
  bad : (Even -> Even) -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}
'''),
        throwsA(
          isA<PositivityViolation>()
              .having((e) => e.dataName, 'dataName', 'Even')
              .having((e) => e.ctorName, 'ctorName', 'bad'),
        ),
      );
    });
  });

  group('uniqueness discipline in mutual blocks', () {
    test('duplicate data name within a block rejected', () {
      expect(
        () => _elab('''
data A : Type { ca : A; }
and data A : Type { ca2 : A; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('duplicate ctor name across block members rejected', () {
      expect(
        () => _elab('''
data A : Type { shared : A; }
and data B : Type { shared : B; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('block member name colliding with outer val rejected', () {
      expect(
        () => _elab('''
val A : Type 1 = Type

data A : Type { x : A; }
and data B : Type { y : B; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });

    test('block ctor name colliding with outer val rejected', () {
      expect(
        () => _elab('''
val shared : Type 1 = Type

data A : Type { shared : A; }
and data B : Type { y : B; }
'''),
        throwsA(isA<DuplicateDeclaration>()),
      );
    });
  });

  group('construction: mutual values can be built and evaluated', () {
    test('esucc (osucc ezero) : Even evaluates to canonical form', () {
      final env = _elabAndCheck('''
data Even : Type {
  ezero : Even;
  esucc : Odd -> Even;
}
and data Odd : Type {
  osucc : Even -> Odd;
}

val two : Even = esucc (osucc ezero)
''');
      // Find `two` and evaluate it in a prior-only ctx.
      final twoIdx = env.bindings.indexWhere((b) => b.name == 'two');
      final priorEnv = TopEnv(env.bindings.sublist(0, twoIdx), env.dataDecls);
      final ctx = priorEnv.toCtx();
      final v = eval(env.bindings[twoIdx].term, ctx.env);
      expect(v, isA<VConstr>());
      final outer = v as VConstr;
      expect(outer.dataName, 'Even');
      expect(outer.ctorName, 'esucc');
      expect(outer.args, hasLength(1));
      final mid = outer.args.single as VConstr;
      expect(mid.dataName, 'Odd');
      expect(mid.ctorName, 'osucc');
      expect(mid.args, hasLength(1));
      final inner = mid.args.single as VConstr;
      expect(inner.dataName, 'Even');
      expect(inner.ctorName, 'ezero');
    });
  });

  group('positivity: deeper block-wide cases', () {
    test('(B -> B) -> A rejected: B in negative pos in A', () {
      expect(
        () => _elab('''
data A : Type {
  bad : (B -> B) -> A;
}
and data B : Type {
  cb : B;
}
'''),
        throwsA(
          isA<PositivityViolation>()
              .having((e) => e.dataName, 'dataName', 'A')
              .having((e) => e.ctorName, 'ctorName', 'bad'),
        ),
      );
    });

    test(
      'List[A] -> B accepted via nested positivity (List covariant in X)',
      () {
        // List is covariant in its param, so A inside `List[A]` sits in
        // a strictly-positive slot even though it appears in the outer
        // Pi's domain: checked by nested positivity, not by the plain
        // occurs-in-domain rule.
        final env = _elab('''
data List[X: Type] : Type {
  nil  : List[X];
  cons : X -> List[X] -> List[X];
}

data A : Type {
  ca : A;
}
and data B : Type {
  cb : List[A] -> B;
}
''');
        expect(env.dataDecls.map((d) => d.name), ['List', 'A', 'B']);
      },
    );
  });

  group('header dependencies: topological elaboration order', () {
    test('A header referencing sibling B elaborates', () {
      // In `data A : B -> Type and data B : Type { ... }`, A's header
      // refers to B. Header elaboration sorts members by their
      // header dependencies and elaborates in that order, so B (no
      // deps) goes first and A's header then resolves B cleanly.
      // A naive source-order pass would hit an unresolved-name error.
      final env = _elab('''
data A : B -> Type {
  ca : (b: B) -> A b;
}
and data B : Type {
  cb : B;
}
''');
      expect(env.dataDecls.map((d) => d.name), containsAll(['A', 'B']));
    });

    test('true cycle is rejected with MutualHeaderCycle', () {
      // `data A : B -> Type and data B : A z -> Type` forms a cycle in
      // the header dependency graph; no topological order exists, so it
      // is rejected with a dedicated error.
      expect(
        () => _elab('''
data A : B -> Type {
  ca : (b: B) -> A b;
}
and data B : A z -> Type {
  cb : (a: A z) -> B a;
}
'''),
        throwsA(
          isA<MutualHeaderCycle>().having(
            (e) => e.cycle,
            'cycle',
            containsAll(['A', 'B']),
          ),
        ),
      );
    });

    test('block referencing an outer (non-block) data works', () {
      final env = _elabAndCheck('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Even : Nat -> Type {
  ezero : Even zero;
}
and data Odd : Nat -> Type {
  oone : Odd (succ zero);
}
''');
      expect(env.dataDecls.map((d) => d.name), ['Nat', 'Even', 'Odd']);
    });
  });

  group('span precision: per-member spans in mutual blocks', () {
    test('each block member carries its own span distinct from block span', () {
      const src = '''
data A : Type {
  ca : A;
}
and data B : Type {
  cb : B;
}
''';
      final p = _parseProg(src);
      final block = p.decls.single.kind as SDataBlockKind;
      expect(block.members, hasLength(2));
      final blockSpan = p.decls.single.span;
      for (final m in block.members) {
        expect(m.span.start, greaterThanOrEqualTo(blockSpan.start));
        expect(m.span.end, lessThanOrEqualTo(blockSpan.end));
      }
      // Regression: members once all shared a single block-wide span.
      expect(block.members[0].span, isNot(equals(block.members[1].span)));
      expect(
        block.members[0].span.start,
        lessThan(block.members[1].span.start),
      );
    });

    test('DataDecl from a block member carries per-member span', () {
      final env = _elab('''
data A : Type { ca : A; }
and data B : Type { cb : B; }
''');
      final a = env.lookupData('A')!;
      final b = env.lookupData('B')!;
      // Regression: A and B must have distinct per-member spans, not a
      // shared block-wide span.
      expect(a.span, isNot(equals(b.span)));
    });

    test(
      'positivity error in second block member cites the second member span',
      () {
        const src = '''
data A : Type {
  ca : A;
}
and data B : Type {
  bad : (B -> B) -> B;
}
''';
        try {
          _elab(src);
          fail('expected PositivityViolation');
        } on PositivityViolation catch (e) {
          expect(e.dataName, 'B');
          expect(e.ctorName, 'bad');
          // The span points into the ctor's type expression, so at
          // minimum it must not start before `and data B`.
          final andDataBStart = src.indexOf('and data B');
          expect(e.span.start, greaterThanOrEqualTo(andDataBStart));
        }
      },
    );

    test('duplicate ctor across block cites second occurrence span', () {
      const src = '''
data A : Type {
  shared : A;
}
and data B : Type {
  shared : B;
}
''';
      try {
        _elab(src);
        fail('expected DuplicateDeclaration');
      } on DuplicateDeclaration catch (e) {
        expect(e.name, 'shared');
        final bSharedStart = src.indexOf('shared : B');
        expect(e.span.start, greaterThanOrEqualTo(bSharedStart));
      }
    });
  });

  group('end-to-end: mutual Tree example', () {
    test('Forest/Tree mutual recursion structure accepted', () {
      // Parametric mutual blocks work when each member's parameters are
      // independent of the sibling's (here both take just `A : Type`).
      final env = _elabAndCheck('''
data Tree[A: Type] : Type {
  node : A -> Forest[A] -> Tree[A];
}
and data Forest[A: Type] : Type {
  fnil  : Forest[A];
  fcons : Tree[A] -> Forest[A] -> Forest[A];
}
''');
      expect(env.dataDecls.map((d) => d.name), ['Tree', 'Forest']);
      expect(env.bindings.map((b) => b.name), [
        'Tree.rec',
        'Tree.ind',
        'Forest.rec',
        'Forest.ind',
      ]);
    });
  });
}
