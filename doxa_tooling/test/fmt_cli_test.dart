/// Process-level tests for the formatter command.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('doxa fmt', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('doxa-fmt-test-');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'reports parse errors consistently in check and stdout modes',
      () async {
        final file = File('${tempDir.path}/invalid.doxa')
          ..writeAsStringSync('val x = )');

        for (final flag in ['--check', '--stdout']) {
          final result = await Process.run(Platform.resolvedExecutable, [
            'run',
            'bin/doxa.dart',
            'fmt',
            flag,
            file.path,
          ]);

          expect(result.exitCode, equals(1));
          expect(result.stderr, contains('cannot format'));
          expect(result.stderr, isNot(contains('#0')));
        }
      },
    );

    test('rejects unexpected formatter arguments', () async {
      final file = File('${tempDir.path}/valid.doxa')
        ..writeAsStringSync('val x = zero');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/doxa.dart',
        'fmt',
        file.path,
        '--unexpected',
      ]);

      expect(result.exitCode, equals(2));
      expect(result.stderr, contains('Usage: doxa'));
    });
  });
}
