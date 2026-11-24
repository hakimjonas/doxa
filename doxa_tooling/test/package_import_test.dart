/// Tests for `package:` imports resolved through the project package
/// configuration.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:doxa_tooling/src/lsp/handler.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

void main() {
  final stdlibRoot = Directory('../doxa_stdlib').absolute.path;

  group('package: imports', () {
    late Directory project;

    setUpAll(() async {
      project = Directory.systemTemp.createTempSync('doxa-package-import-');
      File('${project.path}/pubspec.yaml').writeAsStringSync('''
name: doxa_package_import_probe
environment:
  sdk: ^3.7.0
dev_dependencies:
  doxa_stdlib:
    path: $stdlibRoot
''');
      final pub = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: project.path);
      expect(pub.exitCode, 0, reason: '${pub.stdout}\n${pub.stderr}');
    });

    tearDownAll(() {
      project.deleteSync(recursive: true);
    });

    test('checkSource resolves the library through the configuration', () {
      final file = File('${project.path}/main.doxa')..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/nat.doxa"

val two : Nat = succ (succ zero)
val four : Nat = plus two two
''');
      final result = _runFile(file);
      expect(result.code, 0, reason: result.stderr);
      expect(result.stdout, contains('OK:'));
    });

    test('domain package re-exports resolve through the package URI', () {
      final file = File('${project.path}/domain.doxa')..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/Nat/package.doxa"

val two : Nat = succ (succ zero)
''');
      final result = _runFile(file);
      expect(result.code, 0, reason: result.stderr);
      expect(result.stdout, contains('OK:'));
    });

    test('the Eqb domain package re-exports the class and its instances', () {
      final file = File('${project.path}/eqb_use.doxa')..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/Eqb/package.doxa"

val natSame : Bool = equals zero zero
val listSame : Bool = equals (cons zero nil) (cons zero nil)
''');
      final result = _runFile(file);
      expect(result.code, 0, reason: result.stderr);
      expect(result.stdout, contains('OK:'));
    });

    test(
      'the Algebra domain package supplies the instances and both folds',
      () {
        final file = File('${project.path}/algebra_use.doxa')
          ..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/Algebra/package.doxa"

val two : Nat = sum Nat (cons (succ zero) (cons (succ zero) nil))
val two_eq : Eq Nat two (succ (succ zero)) = refl two
val viaComm : Nat = sumViaComm Nat (cons (succ zero) (cons (succ zero) nil))
val viaComm_eq : Eq Nat viaComm (succ (succ zero)) = refl viaComm
''');
        final result = _runFile(file);
        expect(result.code, 0, reason: result.stderr);
        expect(result.stdout, contains('OK:'));
      },
    );

    test('the CLI resolves the package URI end to end', () async {
      final file = File('${project.path}/cli.doxa')..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/nat.doxa"

val four : Nat = plus (succ zero) (succ (succ zero))
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'bin/doxa.dart',
        'check',
        file.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('OK:'));
    });

    test('the LSP resolves a package import without diagnostics', () {
      final file = File('${project.path}/lsp.doxa')..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/nat.doxa"

val two : Nat = succ (succ zero)
''');
      final uri = file.uri.toString();
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;

      handler.handle({
        'jsonrpc': '2.0',
        'method': 'textDocument/didOpen',
        'params': {
          'textDocument': {
            'uri': uri,
            'languageId': 'doxa',
            'version': 1,
            'text': file.readAsStringSync(),
          },
        },
      });

      final published = notifications.lastWhere(
        (message) => message['method'] == 'textDocument/publishDiagnostics',
        orElse: () => <String, dynamic>{},
      );
      expect(published, isNotEmpty, reason: 'no diagnostics were published');
      final params = published['params'] as Map<String, dynamic>;
      expect(params['diagnostics'], isEmpty, reason: params.toString());

      final definition = handler.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'textDocument/definition',
        'params': {
          'textDocument': {'uri': uri},
          'position': {'line': 2, 'character': 'val two : '.length},
        },
      });
      expect(definition!['result'], isNotNull, reason: definition.toString());
    });

    test('names a package missing from the configuration', () {
      final file = File('${project.path}/missing.doxa')..writeAsStringSync('''
import "package:absent/stdlib/nat.doxa"

val x = zero
''');
      final result = _runFile(file);
      expect(result.code, 1);
      expect(result.stderr, contains('package import not found'));
      expect(result.stderr, contains('package "absent" is not declared'));
      expect(result.stderr, contains('package_config.json'));
    });

    test('reports a malformed package specifier', () {
      final file = File('${project.path}/malformed.doxa')..writeAsStringSync('''
import "package:no_path"

val x = zero
''');
      final result = _runFile(file);
      expect(result.code, 1);
      expect(
        result.stderr,
        contains('a package import needs a name and a path'),
      );
    });

    test('reports a missing configuration instead of falling back', () {
      final outside = Directory.systemTemp.createTempSync(
        'doxa-no-package-config-',
      );
      addTearDown(() => outside.deleteSync(recursive: true));
      final file = File('${outside.path}/standalone.doxa')
        ..writeAsStringSync('''
import "package:doxa_stdlib/stdlib/nat.doxa"

val x = zero
''');
      final result = _runFile(file);
      expect(result.code, 1);
      expect(result.stderr, contains('package import not found'));
      expect(result.stderr, contains('no .dart_tool/package_config.json'));
    });
  });
}

({int code, String stdout, String stderr}) _runFile(File file) {
  final source = SourceFile(filename: file.path, text: file.readAsStringSync());
  final outBuf = _BufferedSink();
  final errBuf = _BufferedSink();
  final code = checkSource(source, out: outBuf, err: errBuf);
  return (code: code, stdout: outBuf.toString(), stderr: errBuf.toString());
}

class _BufferedSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) {
    _buffer.write(obj);
  }

  @override
  void writeln([Object? obj = '']) {
    _buffer.writeln(obj);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  @override
  String toString() => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
}
