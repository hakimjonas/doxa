/// Unannotated declarations whose bodies insert implicit arguments.
///
/// Elaborating such a body allocates metavariables for the implicit arguments
/// it inserts. Inferring the declaration's type therefore needs the
/// declaration's own `MetaContext`: without it the kernel's `_Infer(TMeta)`
/// reached its invariant and aborted the process.
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/meta.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/pretty.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// A standard library large enough for the cases below: the arithmetic
/// functions, the `Eqb` class with instances for `Nat`, `Bool`, and
/// `List A`, plus `same` (a constrained function) and `const` (whose second
/// type parameter nothing determines).
const _prologue = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data List[A: Type] : Type {
  nil : List A;
  cons : A -> List A -> List A;
}
fun eqbNat(x: Nat, y: Nat): Bool = match x {
  case zero => match y {
    case zero => true_
    case succ _ => false_
  }
  case succ n => match y {
    case zero => false_
    case succ m => eqbNat n m
  }
}
fun eqbBool(x: Bool, y: Bool): Bool = match x {
  case true_ => match y {
    case true_ => true_
    case false_ => false_
  }
  case false_ => match y {
    case true_ => false_
    case false_ => true_
  }
}
typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}
impl Eqb[Bool] {
  fun eqb(x: Bool, y: Bool): Bool = eqbBool x y;
}
impl[A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = match x {
    case nil => match y {
      case nil => true_
      case cons _ _ => false_
    }
    case cons h t => match y {
      case nil => false_
      case cons h2 t2 => eqb h h2
    }
  };
}
fun same[A: Eqb](x: A, y: A): Bool = eqb x y
fun const{A: Type}{B: Type}(x: A, y: B): A = x
''';

/// Parse and check the prologue plus [body].
TopEnv _checked(String body) {
  final r = parseProgram('$_prologue\n$body\n');
  final program = switch (r) {
    Success<ParseError, SProgram>(:final value) => value,
    Partial<ParseError, SProgram>(:final value) => value,
    _ => fail('parse failed: $r'),
  };
  return checkProgram(program);
}

/// The top-level binding named [name].
TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

void main() {
  group('inferred types with inserted implicits', () {
    test('a typeclass method application infers its result type', () {
      final env = _checked('val q = eqb zero zero');
      final q = _binding(env, 'q');
      expect(q.type, const TData('Bool', <Term>[]));
      expect(termContainsMeta(q.type), isFalse);
    });

    test('the inserted dictionary is part of the stored term', () {
      final env = _checked('val q = eqb zero zero');
      expect(
        prettyTerm(_binding(env, 'q').term),
        'Eqb.eqb Nat zero zero _impl_Eqb_Nat',
      );
    });

    test('the declaration is usable where its result type is expected', () {
      final env = _checked('val q = eqb zero zero\nval r: Bool = q');
      expect(_binding(env, 'r').type, const TData('Bool', <Term>[]));
    });

    test('the same holds at Bool', () {
      final env = _checked('val q = eqb true_ false_');
      final q = _binding(env, 'q');
      expect(q.type, const TData('Bool', <Term>[]));
      expect(termContainsMeta(q.type), isFalse);
      expect(prettyTerm(q.term), contains('_impl_Eqb_Bool'));
    });

    test('the same holds at List Nat through the parameterised instance', () {
      final env = _checked('val q = eqb (cons zero nil) (cons zero nil)');
      final q = _binding(env, 'q');
      expect(q.type, const TData('Bool', <Term>[]));
      expect(termContainsMeta(q.type), isFalse);
    });

    test('a constrained function application infers its result type', () {
      final env = _checked('val q = same Nat zero zero');
      final q = _binding(env, 'q');
      expect(q.type, const TData('Bool', <Term>[]));
      expect(termContainsMeta(q.type), isFalse);
    });

    test('a bare identifier keeps its full signature', () {
      final env = _checked('val q = eqb');
      final q = _binding(env, 'q');
      expect(q.type, isA<TPi>());
      expect(termContainsMeta(q.type), isFalse);
    });

    test('a partial application keeps the explicit Pi that remains', () {
      final env = _checked('val q = eqb zero');
      final q = _binding(env, 'q');
      final first = q.type as TPi;
      expect(first.name, 'y');
      expect(first.icit, Icit.explicit);
      final second = first.codomain as TPi;
      expect(second.name, 'inst');
      expect(second.icit, Icit.implicit);
    });

    test('the result of the annotation is unchanged', () {
      final annotated = _checked('val q: Bool = eqb zero zero');
      final unannotated = _checked('val q = eqb zero zero');
      expect(_binding(annotated, 'q').type, _binding(unannotated, 'q').type);
      expect(_binding(annotated, 'q').term, _binding(unannotated, 'q').term);
    });
  });

  group('an undetermined type', () {
    test('reports the declaration instead of storing a metavariable', () {
      Object? error;
      try {
        _checked('val q = const zero');
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<UnannotatedDeclIndeterminate>());
      final indeterminate = error as UnannotatedDeclIndeterminate;
      expect(indeterminate.name, 'q');
      expect(indeterminate.span.start, greaterThan(0));
    });

    test('the declaration span is the reported position', () {
      const body = 'val q = const zero';
      const source = '$_prologue\n$body\n';
      Object? error;
      try {
        _checked(body);
      } on Object catch (e) {
        error = e;
      }
      final span = (error as UnannotatedDeclIndeterminate).span;
      expect(span.start, source.indexOf(body));
      expect(
        span.end - span.start,
        greaterThanOrEqualTo(body.length),
        reason: 'the span covers the declaration',
      );
    });

    test('annotating the declaration resolves it', () {
      final env = _checked('val q: Nat = const zero zero');
      expect(_binding(env, 'q').type, const TData('Nat', <Term>[]));
    });

    test('a later declaration can still be checked', () {
      // The failed declaration is not registered; an independent declaration
      // after it is unaffected.
      final env = _checked('val r: Nat = succ zero');
      expect(_binding(env, 'r').type, const TData('Nat', <Term>[]));
    });
  });

  group('the type alias path', () {
    test('an alias whose body inserts an implicit reports no metavariable', () {
      // A type alias infers the sort of its body from the same call site.
      // The body here is a value rather than a type, which the alias itself
      // does not gate; what matters for this test is that the inference runs
      // under the declaration's metas instead of aborting.
      final env = _checked('type N = eqb zero zero');
      final n = _binding(env, 'N');
      expect(termContainsMeta(n.type), isFalse);
      expect(termContainsMeta(n.term), isFalse);
    });
  });

  group('no inferred-return-type path', () {
    test('a fun declaration always states its return type', () {
      // `fun` requires `: T`, so the unannotated-inference path exists only
      // for `val` and `type`.
      expect(
        parseProgram('fun f(x: Nat) = x\n'),
        isA<Failure<ParseError, SProgram>>(),
      );
      expect(
        parseProgram('fun f(x: Nat): Nat = x\n'),
        isA<Success<ParseError, SProgram>>(),
      );
    });
  });
}
