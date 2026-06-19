/// Unit tests for the structural-recursion walker (`checkStructuralRecursion`).
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

/// Parse a single `fun` declaration and return its [SFunKind].
/// If the parser produces a mutual block, returns the named member.
SFunKind _parseFun(String src, {String? memberName}) {
  final r = parseProgram(src);
  final SProgram prog;
  if (r is Success<ParseError, SProgram>) {
    prog = r.value;
  } else if (r is Partial<ParseError, SProgram>) {
    prog = r.value;
  } else {
    fail('parse failed: $r');
  }
  // Walk decls looking for a top-level SFunKind or SFunBlockKind.
  for (final decl in prog.decls) {
    final kind = decl.kind;
    if (kind is SFunKind) {
      if (memberName == null || kind.name == memberName) return kind;
    } else if (kind is SFunBlockKind) {
      for (final m in kind.members) {
        if (memberName == null || m.fun.name == memberName) return m.fun;
      }
    }
  }
  fail('no matching fun found in program; memberName=$memberName');
}

void main() {
  group('positive: structurally recursive programs accepted', () {
    test('plus on Nat: recursion on designated first arg', () {
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
''');
      checkStructuralRecursion(fun, {'plus'});
    });

    test('pred on Nat: trivial structural recursion', () {
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun pred(n: Nat): Nat = match n {
  case zero => zero
  case succ m => m
}
''');
      checkStructuralRecursion(fun, {'pred'});
    });

    test('mutual even / odd: cross-call on a strict sub-term', () {
      // `isOdd m`, where m is the succ-arm binder (a strict sub-term of n).
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }

fun isEven(n: Nat): Bool = match n {
  case zero => true_
  case succ m => isOdd m
}
and isOdd(n: Nat): Bool = match n {
  case zero => false_
  case succ m => isEven m
}
''', memberName: 'isEven');
      checkStructuralRecursion(fun, {'isEven', 'isOdd'});
    });

    test('nested match: sub-match on a sub-term yields sub-sub-terms', () {
      // `f m2`, where m2 (from the inner succ) is still a sub-term of n.
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun f(n: Nat): Nat = match n {
  case zero => zero
  case succ m => match m {
    case zero => zero
    case succ m2 => f m2
  }
}
''');
      checkStructuralRecursion(fun, {'f'});
    });
  });

  group('negative: non-structural recursion rejected', () {
    test('self-call with the designated arg itself fails', () {
      // `loop n`: n is the designated arg, not a strict sub-term of itself.
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun loop(n: Nat): Nat = loop n
''');
      expect(
        () => checkStructuralRecursion(fun, {'loop'}),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'loop',
          ),
        ),
      );
    });

    test('mutual call passing the caller\'s designated arg fails', () {
      // Neither `g n` nor `f n` decreases the designated arg.
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun f(n: Nat): Nat = g n
and g(n: Nat): Nat = f n
''', memberName: 'f');
      expect(
        () => checkStructuralRecursion(fun, {'f', 'g'}),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'g',
          ),
        ),
      );
    });

    test('unapplied reference (passing function as value) rejected', () {
      // Bare `f` with no args can't be checked against a designated-arg
      // position.
      final fun = _parseFun('''
fun f(x: Type): Type = x
and g(x: Type): Type = f
''', memberName: 'g');
      expect(
        () => checkStructuralRecursion(fun, {'f', 'g'}),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'f',
          ),
        ),
      );
    });

    test('ref inside a non-dep arrow codomain rejected', () {
      // `f A` sits in an arrow codomain; A is g's designated arg, not a
      // sub-term of itself.
      final fun = _parseFun('''
fun f(A: Type): Type = A
and g(A: Type): Type = A -> f A
''', memberName: 'g');
      expect(
        () => checkStructuralRecursion(fun, {'f', 'g'}),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'f',
          ),
        ),
      );
    });

    test('ref inside a let body rejected', () {
      final fun = _parseFun('''
fun f(A: Type): Type = A
and g(A: Type): Type = { val x: Type = A; f x }
''', memberName: 'g');
      expect(
        () => checkStructuralRecursion(fun, {'f', 'g'}),
        throwsA(
          isA<NonStructuralRecursion>().having(
            (e) => e.calleeName,
            'calleeName',
            'f',
          ),
        ),
      );
    });

    test('zero-arg function with a recursive call rejected', () {
      // A zero-arg recursive fun has no designated arg, so any ref to a
      // block member is non-structural. The grammar requires at least
      // one fun parameter, so this can't arise through source; the
      // walker's `designated == null` path exists only for defensiveness.
      // Left as a documentation marker.
    });
  });

  group('calls to non-block names don\'t fire', () {
    test('calls to external top-level names are fine', () {
      // `succ` is a ctor, not a block member, so its use as a function
      // call is unchecked by the structural walker.
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun plus(m: Nat, n: Nat): Nat = match m {
  case zero => n
  case succ m_ => succ (plus m_ n)
}
''');
      checkStructuralRecursion(fun, {'plus'});
    });
  });

  group('shadowing suppresses the check', () {
    test('let-bound shadow of a block member is fine', () {
      // The body's `f` refers to the let binding, not the block member,
      // so shadowing suppresses the recursion check.
      final fun = _parseFun('''
fun f(A: Type): Type = A
and g(A: Type): Type = { val f: Type = A; f }
''', memberName: 'g');
      checkStructuralRecursion(fun, {'f', 'g'});
    });

    test('param-level shadow of a block member is fine', () {
      // `f` inside g's body is the parameter, not the block member.
      final fun = _parseFun('''
fun f(x: Type): Type = x
and g(f: Type): Type = f
''', memberName: 'g');
      checkStructuralRecursion(fun, {'f', 'g'});
    });

    test('lambda-bound shadow is fine', () {
      // The lambda binds `f` (same name as a block member), so `f` in the
      // lambda body is not the block member.
      final fun = _parseFun('''
fun f(x: Type): Type = x
and g(A: Type): Type -> Type = (f: Type) => f
''', memberName: 'g');
      checkStructuralRecursion(fun, {'f', 'g'});
    });
  });

  group('edge cases', () {
    test('non-recursive fun with block members in scope: no-op', () {
      // No reference to any block member in the body, so the walker is a
      // no-op.
      final fun = _parseFun('fun f(x: Type): Type = x');
      checkStructuralRecursion(fun, {'f'});
    });

    test(
      'param-type references to block members are rejected',
      () {
        // A param type that mentions a sibling block member is rejected
        // by the walker's param-type pass (no designated arg there). This
        // needs a zero-param fun, which the grammar disallows, so the
        // case is only illustrative; skipped.
      },
      skip: 'grammar requires at least one fun parameter',
    );
  });

  group('{struct name} annotation', () {
    test('{struct} on a later param is accepted', () {
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun f(a: Nat, b: List): List {struct b} = match b {
  case nil => nil
  case cons x xs => cons x (f a xs)
}
''');
      checkStructuralRecursion(fun, {'f'});
    });

    test('{struct} on first param works (same as default)', () {
      final fun = _parseFun('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun f(n: Nat): Nat {struct n} = match n {
  case zero => zero
  case succ m => f m
}
''');
      checkStructuralRecursion(fun, {'f'});
    });

    test('{struct} on non-existent param rejected at elaboration', () {
      expect(
        () => elabProgram(
          _parseProg('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

fun f(n: Nat): Nat {struct x} = n
'''),
        ),
        throwsA(isA<StructAnnotationNotFound>()),
      );
    });
  });
}

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}
