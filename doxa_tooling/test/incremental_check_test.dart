/// Tests for declaration-prefix reuse in the tooling checker session.
library;

import 'dart:io';

import 'package:doxa_tooling/src/output.dart';
import 'package:doxa_tooling/src/web_check.dart';
import 'package:test/test.dart';

void main() {
  group('IncrementalCheckSession', () {
    const initial = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = first
val third : Bool = second
''';

    test('later edit reuses the earlier declaration prefix', () {
      final session = IncrementalCheckSession(filename: 'incremental.doxa');
      expect(session.update(initial), isA<CheckSuccess>());

      const changed = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = first
val third : Bool = false_
''';
      final output = session.update(changed);
      expect(output, isA<CheckSuccess>());
      expect(session.lastRecheckStart, 3);
      expect(session.lastReusedDeclarationCount, 3);
      expect(session.lastRecheckedDeclarationCount, 1);
      expect(output.toJson(), checkSourceOutput(changed).toJson());
    });

    test('earlier edit rechecks its complete suffix', () {
      final session = IncrementalCheckSession(filename: 'incremental.doxa');
      session.update(initial);
      const changed = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = false_
val third : Bool = second
''';
      expect(session.update(changed), isA<CheckSuccess>());
      expect(session.lastRecheckStart, 2);
      expect(session.lastRecheckedDeclarationCount, 2);
    });

    test('failure followed by repair reuses the successful prefix', () {
      final session = IncrementalCheckSession(filename: 'incremental.doxa');
      session.update(initial);
      const broken = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = first
val third : Bool = Type
''';
      expect(session.update(broken), isA<CheckFailure>());
      expect(session.lastReusedDeclarationCount, 3);
      expect(session.update(initial), isA<CheckSuccess>());
      expect(session.lastReusedDeclarationCount, 3);
      expect(session.lastRecheckedDeclarationCount, 1);
    });

    test('parse failure retains records for a later repair', () {
      final session = IncrementalCheckSession(filename: 'incremental.doxa');
      session.update(initial);
      const broken = 'val first : Bool = true_\n)';

      expect(session.update(broken), isA<CheckFailure>());
      expect(session.lastFallbackReason, 'parse_failure');

      expect(session.update(initial), isA<CheckSuccess>());
      expect(session.lastReusedDeclarationCount, 4);
      expect(session.lastRecheckedDeclarationCount, 0);
    });

    test('repair completes normal forms retained from a failed pass', () {
      final session = IncrementalCheckSession(filename: 'incremental.doxa');
      const broken = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = first
val third : Bool = Type
''';
      const repaired = '''
data Bool : Type { true_ : Bool; false_ : Bool; }
val first : Bool = true_
val second : Bool = first
val third : Bool = second
''';

      expect(session.update(broken), isA<CheckFailure>());
      final output = session.update(repaired);

      expect(output, isA<CheckSuccess>());
      expect(session.lastReusedDeclarationCount, 3);
      expect(output.toJson(), checkSourceOutput(repaired).toJson());
    });

    test('root import change resets import resolution and records', () {
      final directory = Directory.systemTemp.createTempSync(
        'doxa_incremental_',
      );
      try {
        File(
          '${directory.path}/one.doxa',
        ).writeAsStringSync('data One : Type { one : One; }');
        File(
          '${directory.path}/two.doxa',
        ).writeAsStringSync('data Two : Type { two : Two; }');
        final filename = '${directory.path}/root.doxa';
        final session = IncrementalCheckSession(filename: filename);
        expect(session.update('import "one.doxa"'), isA<CheckSuccess>());
        expect(session.update('import "two.doxa"'), isA<CheckSuccess>());
        expect(session.lastFallbackReason, 'root_imports_changed');
        expect(session.lastRecheckStart, 0);
        expect(session.lastReusedDeclarationCount, 0);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });

    test('external import invalidation rebuilds the session baseline', () {
      final directory = Directory.systemTemp.createTempSync(
        'doxa_incremental_',
      );
      try {
        final dependency = File('${directory.path}/dependency.doxa')
          ..writeAsStringSync('data One : Type { one : One; }');
        final session = IncrementalCheckSession(
          filename: '${directory.path}/root.doxa',
        );
        const source = 'import "dependency.doxa"\nval x : One = one\n';
        expect(session.update(source), isA<CheckSuccess>());
        expect(session.importsPath(dependency.path), isTrue);

        dependency.writeAsStringSync('data Two : Type { two : Two; }');
        session.invalidateImports();

        expect(session.update(source), isA<CheckFailure>());
        expect(session.lastFallbackReason, 'initial_check');
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });
}
