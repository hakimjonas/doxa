/// Constructor applications in check mode: the data parameters must be
/// solved from the expected type before the explicit arguments are
/// checked. Otherwise an argument whose type mentions a parameter sees
/// an unsolved meta in a non-pattern spine.
library;

import 'package:doxa/src/check.dart';
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

/// Elaborate and declaration-check [src] the way the CLI does.
TopEnv _elabAndCheck(String src) {
  final program = _parse(src);
  var bindings = <TopBinding>[];
  var dataDecls = <DataDecl>[];
  var classRegistry = <String, ClassInfo>{};
  var namespaceBindings = <String, Set<String>>{};
  for (final decl in program.decls) {
    final produced = elabDecl(
      TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
      decl,
    );
    dataDecls = <DataDecl>[...dataDecls, ...produced.dataDecls];
    bindings = <TopBinding>[
      ...bindings,
      ...checkDeclResult(
        TopEnv(bindings, dataDecls, classRegistry, namespaceBindings),
        produced,
      ),
    ];
    classRegistry = <String, ClassInfo>{
      ...classRegistry,
      ...produced.classRegistry,
    };
    namespaceBindings = mergeNamespace(
      namespaceBindings,
      produced.namespaceBindings,
    );
  }
  return TopEnv(bindings, dataDecls, classRegistry, namespaceBindings);
}

TopBinding _binding(TopEnv env, String name) =>
    env.bindings.firstWhere((b) => b.name == name);

void main() {
  group('constructor parameters from the expected type', () {
    test('Box3 solves a value parameter used in an argument type', () {
      // `R` is the data's second parameter. The recursive argument's
      // type mentions it (`R y x`), so inferring the constructor first
      // leaves `R` unsolved while `f` is checked.
      final env = _elabAndCheck('''
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data Box3[A: Type, R: A -> A -> Prop]: Type {
  box3: (x: A) -> ((y: A) -> R y x -> Box3 A R) -> Box3 A R;
}
val apply_box:
  (R: Nat -> Nat -> Prop) ->
  (f: (y: Nat) -> R y zero -> Box3 Nat R) ->
  Box3 Nat R =
  (R: Nat -> Nat -> Prop) =>
  (f: (y: Nat) -> R y zero -> Box3 Nat R) =>
  box3 zero f
''');
      expect(_binding(env, 'apply_box').name, 'apply_box');
    });

    test('nullary constructors with value parameters still check', () {
      final env = _elabAndCheck('''
data Triv: Prop {
  triv: Triv;
}
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data Box[A: Type, x: A]: Type {
  box: Box A x;
}
data Box2[A: Type, R: A -> A -> Prop]: Type {
  box2: Box2 A R;
}
val b1: Box Nat zero = box
val b2: Box2 Nat ((a: Nat) => (b: Nat) => Triv) = box2
''');
      expect(_binding(env, 'b1').name, 'b1');
      expect(_binding(env, 'b2').name, 'b2');
    });

    test('a wrong constructor argument reports a mismatch at its span', () {
      const src = '''
data Triv: Prop {
  triv: Triv;
}
data Nat: Type {
  zero: Nat;
  succ: Nat -> Nat;
}
data Bool: Type {
  true_: Bool;
  false_: Bool;
}
data Box3[A: Type, R: A -> A -> Prop]: Type {
  box3: (x: A) -> ((y: A) -> R y x -> Box3 A R) -> Box3 A R;
}
val bad: Box3 Nat ((a: Nat) => (b: Nat) => Triv) = box3 zero true_
''';
      TypeMismatch? caught;
      try {
        _elabAndCheck(src);
      } on TypeMismatch catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: 'expected a TypeMismatch');
      final badStart = src.lastIndexOf('true_');
      expect(caught!.span, isNotNull);
      expect(caught.span!.start, badStart);
      expect(caught.span!.end, badStart + 'true_'.length);
    });
  });
}
