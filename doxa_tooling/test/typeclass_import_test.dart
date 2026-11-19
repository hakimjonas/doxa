/// Typeclass instances survive an import: one file declares a class and an
/// instance, another imports it and calls the method.
library;

import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

/// Minimal [IOSink] that records writes.
final class _Sink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? obj) {
    buffer.write(obj);
  }

  @override
  void writeln([Object? obj = '']) {
    buffer.writeln(obj);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('an imported class and instance resolve at the importing site', () {
    final directory = Directory.systemTemp.createTempSync('doxa-typeclass-');
    addTearDown(() => directory.deleteSync(recursive: true));

    File('${directory.path}/eqb.doxa').writeAsStringSync('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => true_
    case succ n => false_
  };
}
''');
    final mainFile = File('${directory.path}/main.doxa')..writeAsStringSync('''
import "eqb.doxa"
val r: Bool = eqb zero zero
''');

    final source = SourceFile(
      filename: mainFile.path,
      text: mainFile.readAsStringSync(),
    );
    final out = _Sink();
    final err = _Sink();
    final code = checkSource(source, out: out, err: err);

    expect(code, 0, reason: 'stderr: ${err.buffer}');
  });

  test('an imported parameterised instance resolves at a concrete type', () {
    final directory = Directory.systemTemp.createTempSync('doxa-typeclass-');
    addTearDown(() => directory.deleteSync(recursive: true));

    File('${directory.path}/eqb.doxa').writeAsStringSync('''
data Nat : Type { zero : Nat; succ : Nat -> Nat; }
data Bool : Type { true_ : Bool; false_ : Bool; }
data List[A: Type] : Type { nil : List A; cons : A -> List A -> List A; }
typeclass Eqb[A: Type] {
  fun eqb(x: A, y: A): Bool;
}
fun andb(a: Bool, b: Bool): Bool = match a {
  case true_ => b
  case false_ => false_
}
impl Eqb[Nat] {
  fun eqb(x: Nat, y: Nat): Bool = match x {
    case zero => match y {
      case zero => true_
      case succ _ => false_
    }
    case succ n => match y {
      case zero => false_
      case succ m => eqb n m
    }
  };
}
impl[A: Eqb] Eqb[List A] {
  fun eqb(x: List A, y: List A): Bool = match x {
    case nil => match y {
      case nil => true_
      case cons _ _ => false_
    }
    case cons h t => match y {
      case nil => false_
      case cons h2 t2 => andb (eqb h h2) (eqb t t2)
    }
  };
}
''');
    final mainFile = File('${directory.path}/main.doxa')..writeAsStringSync('''
import "eqb.doxa"
val r: Bool = eqb (cons zero nil) (cons zero nil)
''');

    final source = SourceFile(
      filename: mainFile.path,
      text: mainFile.readAsStringSync(),
    );
    final out = _Sink();
    final err = _Sink();
    final code = checkSource(source, out: out, err: err);

    expect(code, 0, reason: 'stderr: ${err.buffer}');
  });
}
