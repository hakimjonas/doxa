/// Parser and elaborator support for dotted names (`Nat.rec`, `a.b.c`).
library;

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/surface.dart';
import 'package:doxa/src/term.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

T _unwrap<T>(Result<ParseError, T> r) {
  if (r is Success<ParseError, T>) return r.value;
  if (r is Partial<ParseError, T>) return r.value;
  fail('parse failed: $r');
}

SProgram _parseProg(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

void main() {
  group('parser: dotted names', () {
    test('Nat.rec parses as SDotKind', () {
      final e = _unwrap(parseExpr('Nat.rec'));
      expect(e.kind, isA<SDotKind>());
      final dot = e.kind as SDotKind;
      expect(dot.name, 'rec');
      expect(dot.qualifier.kind, const SIdentKind('Nat'));
    });

    test('Map.Inner.foo is left-folded', () {
      final e = _unwrap(parseExpr('Map.Inner.foo'));
      // SDot(SDot(Map, Inner), foo)
      expect(e.kind, isA<SDotKind>());
      final outer = e.kind as SDotKind;
      expect(outer.name, 'foo');
      expect(outer.qualifier.kind, isA<SDotKind>());
      final inner = outer.qualifier.kind as SDotKind;
      expect(inner.name, 'Inner');
      expect(inner.qualifier.kind, const SIdentKind('Map'));
    });

    test('List[A].foo composes type-args with dot', () {
      final e = _unwrap(parseExpr('List[A].foo'));
      // SDot(SApp(List, A), foo)
      expect(e.kind, isA<SDotKind>());
      final dot = e.kind as SDotKind;
      expect(dot.name, 'foo');
      expect(dot.qualifier.kind, isA<SAppKind>());
    });

    test('Nat.rec x y: dot binds tighter than juxtaposition', () {
      final e = _unwrap(parseExpr('Nat.rec x y'));
      // SApp(SApp(SDot(Nat, rec), x), y)
      expect(e.kind, isA<SAppKind>());
      final outer = e.kind as SAppKind;
      expect(outer.arg.kind, const SIdentKind('y'));
      expect(outer.fn.kind, isA<SAppKind>());
      final inner = outer.fn.kind as SAppKind;
      expect(inner.arg.kind, const SIdentKind('x'));
      expect(inner.fn.kind, isA<SDotKind>());
      final dot = inner.fn.kind as SDotKind;
      expect(dot.name, 'rec');
    });

    test('bare identifier still works with no dot', () {
      final e = _unwrap(parseExpr('Nat'));
      expect(e.kind, const SIdentKind('Nat'));
    });
  });

  group('elab: dotted names resolve to top-level bindings', () {
    test('Nat.rec elaborates to TTop referring to the Nat.rec binding', () {
      final prog = _parseProg('''
data Nat : Type {
  zero : Nat;
  succ : Nat -> Nat;
}

val r : (P: Nat -> Type) -> P zero ->
          ((n: Nat) -> P n -> P (succ n)) ->
          (n: Nat) -> P n
       = Nat.rec
''');
      // Top-level refs elaborate to TTop(name), so `r` becomes
      // TTop("Nat.rec").
      final env = elabProgram(prog);
      expect(env.dataDecls.length, 1);
      final rBinding = env.bindings.firstWhere((b) => b.name == 'r');
      expect(rBinding.term, isA<TTop>());
      expect((rBinding.term as TTop).name, 'Nat.rec');
    });

    test('val using Nat.rec resolves correctly', () {
      final prog = _parseProg('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }

val myRec = Nat.rec
''');
      final env = elabProgram(prog);
      final myRec = env.bindings.firstWhere((b) => b.name == 'myRec');
      expect(myRec.term, isA<TTop>());
      expect((myRec.term as TTop).name, 'Nat.rec');
    });

    test('unresolved dotted name fires UnresolvedName', () {
      final prog = _parseProg('val x = Bogus.rec');
      expect(
        () => elabProgram(prog),
        throwsA(
          isA<UnresolvedName>().having((e) => e.name, 'name', 'Bogus.rec'),
        ),
      );
    });

    test('three-level qualified name composes string correctly', () {
      // We don't have any three-level binding to resolve to, so we
      // just verify the flatten-to-string error carries the whole
      // chain.
      final prog = _parseProg('val x = A.B.C');
      expect(
        () => elabProgram(prog),
        throwsA(isA<UnresolvedName>().having((e) => e.name, 'name', 'A.B.C')),
      );
    });
  });
}
