/// Strict-positivity checks on `data` declarations: canonical
/// acceptances/rejections plus nested positivity via per-parameter
/// covariance tracking.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

TopEnv _elab(String src) => elabProgram(_parse(src));

void _expectPositivityError(
  String src, {
  required String dataName,
  required String ctorName,
  int? argIndex,
}) {
  expect(
    () => _elab(src),
    throwsA(
      isA<PositivityViolation>()
          .having((e) => e.dataName, 'dataName', dataName)
          .having((e) => e.ctorName, 'ctorName', ctorName)
          .having((e) => e.argIndex, 'argIndex', argIndex ?? anything),
    ),
  );
}

void main() {
  group('accepts standard inductive types', () {
    test('Nat', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      expect(env.dataDecls, hasLength(1));
    });

    test('List[A]', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      expect(env.dataDecls, hasLength(1));
    });

    test('Vec[A] : Nat -> Type', () {
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
      expect(env.dataDecls, hasLength(2));
    });

    test('binary tree with two recursive args', () {
      final env = _elab('''
data Tree : Type {
  leaf : Tree;
  node : Tree -> Tree -> Tree;
}
''');
      expect(env.dataDecls, hasLength(1));
    });

    test('recursive arg followed by non-recursive in the middle', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

data Pair : Type {
  mk : Nat -> Pair -> Pair;
}
''');
      expect(env.dataDecls, hasLength(2));
    });

    test('parameter-dependent ctor that does not reference the inductive', () {
      final env = _elab('''
data Option[A: Type] : Type {
  none_ : Option[A];
  some_ : A -> Option[A];
}
''');
      expect(env.dataDecls, hasLength(1));
    });

    test('Prop-sorted ADT with self-recursion in positive position', () {
      final env = _elab('''
data True : Prop {
  tt : True;
}
''');
      expect(env.dataDecls, hasLength(1));
    });
  });

  group('rejects strictly-negative occurrences', () {
    test('the canonical Bad: (Bad -> Bad) -> Bad', () {
      _expectPositivityError(
        '''
data Bad : Type {
  bad : (Bad -> Bad) -> Bad;
}
''',
        dataName: 'Bad',
        ctorName: 'bad',
        argIndex: 0,
      );
    });

    test('negative self-ref inside a named-Pi ctor arg', () {
      // `((x: Bad) -> Bad) -> Bad`, the ctor takes one argument,
      // whose type is a named Pi whose domain is `Bad`. That's a
      // negative occurrence inside the arg type.
      _expectPositivityError(
        '''
data Bad : Type {
  bad : ((x: Bad) -> Bad) -> Bad;
}
''',
        dataName: 'Bad',
        ctorName: 'bad',
      );
    });

    test('Bad nested in a domain: ((Bad -> Nat) -> Bad) -> Bad', () {
      _expectPositivityError(
        '''
data Nat : Type {
  zero : Nat;
}

data Bad : Type {
  bad : ((Bad -> Nat) -> Bad) -> Bad;
}
''',
        dataName: 'Bad',
        ctorName: 'bad',
      );
    });

    test('parametric data type with negative self-reference', () {
      _expectPositivityError(
        '''
data Weird[A: Type] : Type {
  mk : (Weird[A] -> A) -> Weird[A];
}
''',
        dataName: 'Weird',
        ctorName: 'mk',
      );
    });
  });

  group('nested positivity (via per-parameter covariance)', () {
    test('Tree with List[Tree] is accepted (List covariant in A)', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

data Tree : Type {
  leaf : Tree;
  node : List[Tree] -> Tree;
}
''');
      expect(env.dataDecls.map((d) => d.name), ['List', 'Tree']);
    });

    test('RoseTree[A] with List[RoseTree[A]] is accepted', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}

data RoseTree[A: Type] : Type {
  node : A -> List[RoseTree[A]] -> RoseTree[A];
}
''');
      expect(env.dataDecls.map((d) => d.name), ['List', 'RoseTree']);
    });

    test('List is covariant in its parameter A', () {
      final env = _elab('''
data List[A: Type] : Type {
  nil  : List[A];
  cons : A -> List[A] -> List[A];
}
''');
      expect(env.lookupData('List')!.paramsCovariant, [true]);
    });

    test('Weird[A] with A in negative position is NOT covariant in A', () {
      final env = _elab('''
data Weird[A: Type] : Type {
  mk : (A -> A) -> Weird[A];
}
''');
      expect(env.lookupData('Weird')!.paramsCovariant, [false]);
    });

    test('Tree nested in a non-covariant constructor is still rejected', () {
      // Weird is non-covariant in A because its ctor takes (A -> A).
      // So using Weird[Tree] where Tree is being defined should be
      // rejected: Tree occupies a non-covariant slot.
      _expectPositivityError(
        '''
data Weird[A: Type] : Type {
  mk : (A -> A) -> Weird[A];
}

data Tree : Type {
  leaf : Tree;
  node : Weird[Tree] -> Tree;
}
''',
        dataName: 'Tree',
        ctorName: 'node',
      );
    });

    test('non-parametric inductive has empty paramsCovariant', () {
      final env = _elab('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}
''');
      expect(env.lookupData('Nat')!.paramsCovariant, isEmpty);
    });
  });

  group('surface-ergonomics details', () {
    test('positivity diagnostic cites the arg span', () {
      const r = _elab;
      try {
        r('''
data Bad : Type {
  bad : (Bad -> Bad) -> Bad;
}
''');
        fail('should have thrown');
      } on PositivityViolation catch (e) {
        expect(e.dataName, 'Bad');
        expect(e.ctorName, 'bad');
        expect(e.argIndex, 0);
        // The span comes from the surface ctor type, which the parser
        // populates, so it must not be synthetic.
        expect(e.span.isSynthetic, isFalse);
        expect(e.span.start >= 0, isTrue);
      }
    });

    test(
      'later ctor with good positivity still fires error on earlier bad ctor',
      () {
        _expectPositivityError(
          '''
data T : Type {
  bad : (T -> T) -> T;
  good : T -> T;
}
''',
          dataName: 'T',
          ctorName: 'bad',
        );
      },
    );
  });
}
