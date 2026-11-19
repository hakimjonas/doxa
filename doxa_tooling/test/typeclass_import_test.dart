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
}
