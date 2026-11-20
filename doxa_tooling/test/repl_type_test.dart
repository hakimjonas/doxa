/// REPL `:type` and `:norm` infer implicit arguments and display the
/// elaboration-time type, including bare constructors.
library;

import 'package:doxa/src/prelude.dart' show loadPrelude;
import 'package:doxa_tooling/src/repl.dart';
import 'package:test/test.dart';

ReplSession _declare(ReplSession session, String input) {
  final (result, next) = session.processInput(input);
  if (result is ReplError) {
    fail('declaration failed: ${result.message}');
  }
  expect(result, isA<ReplDeclResult>());
  return next;
}

String _type(ReplSession session, String expr) {
  final (result, _) = session.processInput(':type $expr');
  if (result is ReplError) {
    fail(':type $expr failed: ${result.message}');
  }
  expect(result, isA<ReplMeta>());
  return (result as ReplMeta).text;
}

String _norm(ReplSession session, String expr) {
  final (result, _) = session.processInput(':norm $expr');
  if (result is ReplError) {
    fail(':norm $expr failed: ${result.message}');
  }
  expect(result, isA<ReplMeta>());
  return (result as ReplMeta).text;
}

ReplSession _session() {
  final prelude = loadPrelude();
  var session = ReplSession(
    bindings: prelude.bindings,
    dataDecls: prelude.dataDecls,
    namespaceBindings: prelude.namespaceBindings,
  );
  session = _declare(
    session,
    'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
  );
  session = _declare(
    session,
    'data Bool : Type { true_ : Bool; false_ : Bool; }',
  );
  session = _declare(
    session,
    'data List[A: Type] : Type { nil : List A; cons : A -> List A -> List A; }',
  );
  session = _declare(session, 'fun id2{A: Type}(x: A): A = x');
  session = _declare(
    session,
    'typeclass Eqb[A: Type] { fun eqb(x: A, y: A): Bool; }',
  );
  session = _declare(session, '''
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}
''');
  session = _declare(session, 'fun same[A: Eqb](x: A, y: A): Bool = eqb x y');
  return session;
}

void main() {
  late ReplSession session;

  setUp(() {
    session = _session();
  });

  test(':type and :norm insert the implicit argument of id2', () {
    expect(_type(session, 'id2 zero'), 'Nat');
    expect(_norm(session, 'id2 zero'), 'zero');
  });

  test(':type and :norm solve the implicit constructor argument of refl', () {
    expect(_type(session, 'refl zero'), 'Eq Nat zero zero');
    expect(_norm(session, 'refl zero'), 'refl Nat zero');
  });

  test(':type and :norm insert a typeclass dictionary', () {
    expect(_type(session, 'eqb zero zero'), 'Bool');
    expect(_norm(session, 'eqb zero zero'), 'true_');
  });

  test(
    ':type supplies the explicit type argument of a constrained function',
    () {
      expect(_type(session, 'same Nat zero zero'), 'Bool');
    },
  );

  test(':type handles nested applications', () {
    expect(_type(session, 'id2 (id2 zero)'), 'Nat');
    expect(_type(session, 'refl (id2 zero)'), 'Eq Nat zero zero');
  });

  test(':type a partial application keeps the remaining explicit Pi', () {
    final text = _type(session, 'eqb zero');
    expect(text, contains('(y: Nat)'));
    expect(text, contains('Eqb'));
    expect(text, contains('Bool'));
    expect(text, contains('->'));
    // The dictionary is not applied while the explicit argument is missing;
    // once it is supplied, the type is plain Bool.
    expect(_type(session, 'eqb zero zero'), 'Bool');
  });

  test(':type a bare constructor shows its signature', () {
    final text = _type(session, 'refl');
    expect(text, contains('Eq A x x'));
    expect(text, contains('->'));
  });

  test(':type nil and a nullary constructor show their types', () {
    final nilType = _type(session, 'nil');
    expect(nilType, contains('List'));
    expect(nilType, contains('->'));
    expect(_type(session, 'zero'), 'Nat');
  });

  test('a genuinely ill-typed application still reports a diagnostic', () {
    final (result, _) = session.processInput(':type succ true_');
    expect(result, isA<ReplError>());
    expect((result as ReplError).message, contains('type mismatch'));
  });
}
