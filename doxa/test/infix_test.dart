/// Infix arithmetic and comparison operators: parsing, expansion, precedence,
/// associativity, name resolution, and typing.
library;

import 'package:doxa/src/check.dart' show TypeMismatch;
import 'package:doxa/src/elab.dart';
import 'package:doxa/src/eval.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:doxa/src/value.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// A minimal standard library for these tests: `Nat`, `Bool`, `List`, the
/// arithmetic functions the operators expand to, and the `Eqb` class with its
/// three instances.
///
/// The instance bodies call top-level comparison functions. An instance body
/// cannot resolve the instance being defined, so the recursion lives outside
/// it, as in `doxa_stdlib/lib/stdlib/eqb_instances.doxa`.
const _prologue = '''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data List[A: Type] : Type {
  nil : List A;
  cons : A -> List A -> List A;
}
fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
fun mult(m: Nat, n: Nat): Nat = match m {
  case zero => zero
  case succ m_ => plus n (mult m_ n)
}
fun leq(m: Nat, n: Nat): Bool = match m {
  case zero => true_
  case succ m_ => match n {
    case zero => false_
    case succ n_ => leq m_ n_
  }
}
fun and_(a: Bool, b: Bool): Bool = match a {
  case true_ => b
  case false_ => false_
}
typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }
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
fun eqbList[A: Eqb](xs: List A, ys: List A): Bool {struct xs} = match xs {
  case nil => match ys {
    case nil => true_
    case cons _ _ => false_
  }
  case cons h t => match ys {
    case nil => false_
    case cons h2 t2 => and_ (eqb h h2) (eqbList A t t2)
  }
}
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = eqbNat x y;
}
impl Eqb[Bool] {
  fun eqb(x: Bool, y: Bool): Bool = eqbBool x y;
}
impl[A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = eqbList A x y;
}
''';

/// Parse a program, asserting success.
SProgram _pp(String input) {
  final r = parseProgram(input);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

/// Parse an expression, asserting success.
SExpr _expr(String input) {
  final r = parseExpr(input);
  if (r is Success<ParseError, SExpr>) return r.value;
  if (r is Partial<ParseError, SExpr>) return r.value;
  fail('parse failed: $r');
}

/// The prelude supplies `Eq` and `refl`.
final PreludeData _prelude = loadPrelude();

/// Elaborate and declaration-check the prologue plus [body] the way the CLI
/// does, starting from the prelude.
TopEnv _checked(String body) {
  var env = TopEnv(
    _prelude.bindings,
    _prelude.dataDecls,
    const {},
    _prelude.namespaceBindings,
  );
  for (final decl in _pp('$_prologue\n$body').decls) {
    final produced = elabDecl(env, decl);
    final checked = checkDeclResult(
      TopEnv(
        env.bindings,
        [...env.dataDecls, ...produced.dataDecls],
        env.classRegistry,
        env.namespaceBindings,
      ),
      produced,
    );
    env = TopEnv(
      [...env.bindings, ...checked],
      [...env.dataDecls, ...produced.dataDecls],
      {...env.classRegistry, ...produced.classRegistry},
      mergeNamespace(env.namespaceBindings, produced.namespaceBindings),
    );
  }
  return env;
}

/// The declared or inferred type of the top-level binding [name].
Term _typeOf(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name).type;

/// The normal form of the top-level binding [name].
Value _valueOf(TopEnv env, String name) =>
    eval(env.bindings.firstWhere((b) => b.name == name).term, env.toCtx().env);

/// Shape-only comparison: two expressions denote the same term when their
/// kinds match with every span dropped.
SExprKind _shape(SExpr e) => switch (e.kind) {
  SAppKind(:final fn, :final arg) => SAppKind(_shaped(fn), _shaped(arg)),
  SPiKind(:final param, :final domain, :final codomain) => SPiKind(
    param,
    _shaped(domain),
    _shaped(codomain),
  ),
  SLamKind(:final param, :final domain, :final body) => SLamKind(
    param,
    domain == null ? null : _shaped(domain),
    _shaped(body),
  ),
  final k => k,
};

SExpr _shaped(SExpr e) => SExpr(_shape(e), DoxaSpan.synthetic);

/// Assert that two expressions have the same shape.
void expectSameTerm(SExpr a, SExpr b) => expect(_shape(a), equals(_shape(b)));

/// The parse errors of a failing input.
List<String> _parseErrorMessages(String input) {
  final r = parseProgram('val _x = $input\n');
  expect(r, isA<Failure<ParseError, SProgram>>(), reason: 'expected a failure');
  return [for (final e in (r as Failure<ParseError, SProgram>).errors) '$e'];
}

void main() {
  group('expansion', () {
    test('a + b is plus a b', () {
      expectSameTerm(_expr('a + b'), _expr('plus a b'));
    });

    test('a * b is mult a b', () {
      expectSameTerm(_expr('a * b'), _expr('mult a b'));
    });

    test('a <= b is leq a b', () {
      expectSameTerm(_expr('a <= b'), _expr('leq a b'));
    });

    test('a == b is eqb a b', () {
      expectSameTerm(_expr('a == b'), _expr('eqb a b'));
    });

    test('the expanded identifier carries the operator span', () {
      final outer = _expr('a + b').kind as SAppKind;
      final inner = outer.fn.kind as SAppKind;
      expect(inner.fn.kind, const SIdentKind('plus'));
      expect(inner.fn.span.start, 2, reason: 'span starts at the "+"');
      expect(inner.fn.span.end, 3, reason: 'span covers the "+" alone');
    });
  });

  group('precedence', () {
    test('a + b * c groups as a + (b * c)', () {
      expectSameTerm(_expr('a + b * c'), _expr('plus a (mult b c)'));
    });

    test('a * b + c groups as (a * b) + c', () {
      expectSameTerm(_expr('a * b + c'), _expr('plus (mult a b) c'));
    });

    test('application binds tighter than +', () {
      expectSameTerm(_expr('f a + b'), _expr('plus (f a) b'));
    });

    test('+ binds tighter than <=', () {
      expectSameTerm(_expr('a + b <= c'), _expr('leq (plus a b) c'));
    });

    test('* binds tighter than <=', () {
      expectSameTerm(_expr('a <= b * c'), _expr('leq a (mult b c)'));
    });

    test('parentheses override precedence', () {
      expectSameTerm(_expr('(a + b) * c'), _expr('mult (plus a b) c'));
    });

    test('the arrow is looser than the comparisons', () {
      final head = _expr('a <= b -> c').kind as SPiKind;
      expect(head.param, isNull);
      expectSameTerm(head.domain, _expr('a <= b'));
    });
  });

  group('associativity', () {
    test('a + b + c groups as (a + b) + c', () {
      expectSameTerm(_expr('a + b + c'), _expr('plus (plus a b) c'));
    });

    test('a * b * c groups as (a * b) * c', () {
      expectSameTerm(_expr('a * b * c'), _expr('mult (mult a b) c'));
    });

    test('a + (b + c) keeps the parentheses', () {
      expectSameTerm(_expr('a + (b + c)'), _expr('plus a (plus b c)'));
    });

    test('a <= b <= c is rejected, naming <=', () {
      final messages = _parseErrorMessages('a <= b <= c');
      expect(
        messages.any((m) => m.contains('"<="') && m.contains('associate')),
        isTrue,
        reason: messages.join('\n'),
      );
    });

    test('a == b == c is rejected, naming ==', () {
      final messages = _parseErrorMessages('a == b == c');
      expect(
        messages.any((m) => m.contains('"=="') && m.contains('associate')),
        isTrue,
        reason: messages.join('\n'),
      );
    });

    test('a <= b == c is rejected, naming ==', () {
      final messages = _parseErrorMessages('a <= b == c');
      expect(
        messages.any((m) => m.contains('"=="')),
        isTrue,
        reason: messages.join('\n'),
      );
    });

    test('a == b <= c is rejected, naming <=', () {
      final messages = _parseErrorMessages('a == b <= c');
      expect(
        messages.any((m) => m.contains('"<="')),
        isTrue,
        reason: messages.join('\n'),
      );
    });

    test('the diagnostic is located at the second operator', () {
      const source = 'val _x = a <= b <= c\n';
      final r = parseProgram(source);
      expect(r, isA<Failure<ParseError, SProgram>>());
      final failure = r as Failure<ParseError, SProgram>;
      expect(failure.furthest.offset, source.lastIndexOf('<='));
    });

    test('a parenthesized left operand parses', () {
      expectSameTerm(_expr('(a <= b) <= c'), _expr('leq (leq a b) c'));
    });

    test('a parenthesized right operand parses', () {
      expectSameTerm(_expr('a <= (b <= c)'), _expr('leq a (leq b c)'));
    });
  });

  group('typing', () {
    test('+ produces Nat', () {
      final env = _checked('val p = zero + succ zero');
      expect(_typeOf(env, 'p'), const TData('Nat', <Term>[]));
    });

    test('* produces Nat', () {
      final env = _checked('val p = succ zero * succ zero');
      expect(_typeOf(env, 'p'), const TData('Nat', <Term>[]));
    });

    test('+ computes', () {
      final env = _checked('val p = zero + succ zero');
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'succ');
    });

    test('<= produces Bool', () {
      final env = _checked('val p = zero <= succ zero');
      expect(_typeOf(env, 'p'), const TData('Bool', <Term>[]));
    });

    test('<= computes', () {
      final env = _checked('val p = zero <= succ zero');
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'true_');
    });

    // A typeclass-method application is annotated here. Inferring the type of
    // an unannotated one trips a pre-existing kernel invariant
    // ("infer reached TMeta with no MetaContext"); see the report.
    test('== produces Bool at Nat', () {
      final env = _checked('val p: Bool = succ zero == succ zero');
      expect(_typeOf(env, 'p'), const TData('Bool', <Term>[]));
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'true_');
    });

    test('== is rejected where Nat is expected', () {
      expect(
        () => _checked('val p: Nat = succ zero == succ zero'),
        throwsA(isA<TypeMismatch>()),
      );
    });

    test('== resolves the Bool instance', () {
      final env = _checked('val p: Bool = true_ == false_');
      expect(_typeOf(env, 'p'), const TData('Bool', <Term>[]));
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'false_');
    });

    test('== resolves the List Nat instance', () {
      final env = _checked('val p: Bool = cons zero nil == cons zero nil');
      expect(_typeOf(env, 'p'), const TData('Bool', <Term>[]));
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'true_');
    });

    test('== resolves the List element instance, not just the outer one', () {
      final env = _checked(
        'val p: Bool = cons zero nil == cons (succ zero) nil',
      );
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'false_');
    });

    test('a prefix application and the infix form denote the same term', () {
      final env = _checked(
        'val p = zero + zero\n'
        'val q = plus zero zero\n'
        'val same: Eq Nat p q = refl (plus zero zero)',
      );
      expect((_typeOf(env, 'same') as TData).name, 'Eq');
    });
  });

  group('name resolution', () {
    test('a missing plus is reported at the operator, not the expression', () {
      const source = 'val _x = zero + zero\n';
      Object? error;
      try {
        elabProgram(_pp(source));
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<UnresolvedName>());
      final unresolved = error as UnresolvedName;
      expect(unresolved.name, 'plus');
      expect(unresolved.span.start, source.indexOf('+'));
      expect(unresolved.span.end, source.indexOf('+') + 1);
    });

    test('a block-local plus shadows the top-level one for a + b', () {
      final env = _checked('''
val p = { val plus = (x: Nat) => (y: Nat) => x; succ zero + zero }
''');
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'succ');
    });

    test('the local shadow applies to the prefix form too', () {
      final env = _checked('''
val p = { val plus = (x: Nat) => (y: Nat) => x; plus (succ zero) zero }
''');
      expect((_valueOf(env, 'p') as VConstr).ctorName, 'succ');
    });
  });

  group('calc chains', () {
    test('a one-step chain over + checks', () {
      final env = _checked('''
val chain: Eq Nat (zero + zero) (plus zero zero) =
  calc(zero + zero = plus zero zero := refl (plus zero zero))
''');
      expect((_typeOf(env, 'chain') as TData).name, 'Eq');
    });

    test('a two-step chain over + checks', () {
      final env = _checked('''
val chain: Eq Nat (zero + zero) zero =
  calc(
    zero + zero = plus zero zero := refl (plus zero zero);
    plus zero zero = zero := refl zero
  )
''');
      expect((_typeOf(env, 'chain') as TData).name, 'Eq');
    });
  });
}
