import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doxa_tooling/src/lsp/transport.dart';
import 'package:test/test.dart';

void main() {
  group('doxa lsp stdio', () {
    test('continues after a malformed frame and exits on exit', () async {
      final server = await _LspServer.start();
      addTearDown(server.dispose);

      server.sendRaw('Content-Length: 1\r\n\r\n{');
      server.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{},
      });

      final initialized = await server.nextMessage();
      expect(initialized['id'], 1);
      expect(initialized['result'], isA<Map<String, dynamic>>());

      server.send({'jsonrpc': '2.0', 'method': 'exit'});
      expect(await server.process.exitCode, 0);
    });

    test('publishes diagnostics and completes shutdown over stdio', () async {
      final server = await _LspServer.start();
      addTearDown(server.dispose);
      const uri = 'file:///workspace/broken.doxa';

      server.send({
        'jsonrpc': '2.0',
        'method': 'textDocument/didOpen',
        'params': {
          'textDocument': {
            'uri': uri,
            'languageId': 'doxa',
            'version': 7,
            'text': 'val broken : Missing = missing\n',
          },
        },
      });

      final diagnostics = await server.nextMessageWhere(
        (m) => m['method'] == 'textDocument/publishDiagnostics',
      );
      expect(diagnostics['method'], 'textDocument/publishDiagnostics');
      expect((diagnostics['params'] as Map<String, dynamic>)['uri'], uri);
      expect((diagnostics['params'] as Map<String, dynamic>)['version'], 7);
      expect(
        (diagnostics['params'] as Map<String, dynamic>)['diagnostics'],
        isNotEmpty,
      );

      server.send({'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown'});
      expect(await server.nextMessageWhere((m) => m['id'] == 2), {
        'jsonrpc': '2.0',
        'id': 2,
        'result': null,
      });
      server.send({'jsonrpc': '2.0', 'method': 'exit'});
      expect(await server.process.exitCode, 0);
    });

    test(
      'publishes a concise diagnostic at an incomplete expression',
      () async {
        final server = await _LspServer.start();
        addTearDown(server.dispose);
        const source = 'val value : Type =\n';

        server.send({
          'jsonrpc': '2.0',
          'method': 'textDocument/didOpen',
          'params': {
            'textDocument': {
              'uri': 'file:///workspace/incomplete.doxa',
              'languageId': 'doxa',
              'version': 1,
              'text': source,
            },
          },
        });

        final notification = await server.nextMessageWhere(
          (m) => m['method'] == 'textDocument/publishDiagnostics',
        );
        final diagnostics =
            (notification['params'] as Map<String, dynamic>)['diagnostics']
                as List<dynamic>;
        expect(diagnostics, hasLength(1));
        final diagnostic = diagnostics.single as Map<String, dynamic>;
        expect(diagnostic['message'], 'expected an expression');
        expect((diagnostic['range'] as Map<String, dynamic>)['start'], {
          'line': 1,
          'character': 0,
        });

        server.send({'jsonrpc': '2.0', 'method': 'exit'});
        expect(await server.process.exitCode, 0);
      },
    );

    test(
      'rechecks dependents against an unsaved imported data declaration',
      () async {
        final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final dependency = File('${directory.path}/dependency.doxa')
          ..writeAsStringSync(
            'data Status : Type {\n'
            '  ready : Status;\n'
            '  blocked : Status;\n'
            '}\n'
            '\n'
            'fun keep(status: Status) : Status = status\n',
          );
        final main = File('${directory.path}/main.doxa')..writeAsStringSync(
          'import "dependency.doxa"\n'
          '\n'
          'val current : Status = ready\n'
          'fun preserve(status: Status) : Status = keep status\n',
        );
        const unsavedDependency =
            'data State : Type {\n'
            '  ready : State;\n'
            '  blocked : State;\n'
            '}\n'
            '\n'
            'fun keep(status: State) : State = status\n';
        final server = await _LspServer.start();
        addTearDown(server.dispose);

        server.send(_didOpen(main.uri.toString(), main.readAsStringSync()));
        expect(
          _diagnostics(
            await server.nextMessageWhere(
              (m) => m['method'] == 'textDocument/publishDiagnostics',
            ),
          ),
          isEmpty,
        );

        server.send(_didOpen(dependency.uri.toString(), unsavedDependency));
        expect(
          _diagnostics(
            await server.nextMessageWhere(
              (m) => m['method'] == 'textDocument/publishDiagnostics',
            ),
          ),
          isEmpty,
        );
        final staleMain = await server.nextMessageWhere(
          (m) => m['method'] == 'textDocument/publishDiagnostics',
        );
        expect(
          (staleMain['params'] as Map<String, dynamic>)['uri'],
          main.uri.toString(),
        );
        final staleDiagnostics = _diagnostics(staleMain);
        expect(staleDiagnostics, isNotEmpty);
        expect(
          (staleDiagnostics.first as Map<String, dynamic>)['message'],
          isNot(contains('TypeMismatch(')),
        );

        server.send({
          'jsonrpc': '2.0',
          'method': 'textDocument/didClose',
          'params': {
            'textDocument': {'uri': dependency.uri.toString()},
          },
        });
        expect(
          _diagnostics(
            await server.nextMessageWhere(
              (m) => m['method'] == 'textDocument/publishDiagnostics',
            ),
          ),
          isEmpty,
        );
        final restoredMain = await server.nextMessageWhere(
          (m) => m['method'] == 'textDocument/publishDiagnostics',
        );
        expect(
          (restoredMain['params'] as Map<String, dynamic>)['uri'],
          main.uri.toString(),
        );
        expect(_diagnostics(restoredMain), isEmpty);

        server.send({'jsonrpc': '2.0', 'method': 'exit'});
        expect(await server.process.exitCode, 0);
      },
    );
  });
}

Map<String, dynamic> _didOpen(String uri, String text) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/didOpen',
  'params': {
    'textDocument': {
      'uri': uri,
      'languageId': 'doxa',
      'version': 1,
      'text': text,
    },
  },
};

List<dynamic> _diagnostics(Map<String, dynamic> message) =>
    (message['params'] as Map<String, dynamic>)['diagnostics'] as List<dynamic>;

final class _LspServer {
  _LspServer._(this.process, this._messages);

  final Process process;
  final StreamIterator<Map<String, dynamic>> _messages;

  static Future<_LspServer> start() async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'bin/doxa.dart',
      'lsp',
    ]);
    final reader = LspReader();
    final messages = StreamIterator(
      process.stdout.asyncExpand(
        (bytes) =>
            Stream<Map<String, dynamic>>.fromIterable(reader.feed(bytes)),
      ),
    );
    return _LspServer._(process, messages);
  }

  void send(Map<String, dynamic> message) {
    final body = utf8.encode(jsonEncode(message));
    sendRaw('Content-Length: ${body.length}\r\n\r\n${utf8.decode(body)}');
  }

  void sendRaw(String message) {
    process.stdin.add(utf8.encode(message));
  }

  Future<Map<String, dynamic>> nextMessage() async =>
      nextMessageWhere((_) => true);

  /// Next message matching [predicate], skipping any other messages in
  /// between (the server interleaves notifications such as
  /// `doxa/proofState` with responses and diagnostics).
  Future<Map<String, dynamic>> nextMessageWhere(
    bool Function(Map<String, dynamic>) predicate,
  ) async {
    while (true) {
      final hasMessage = await _messages.moveNext().timeout(
        const Duration(seconds: 10),
      );
      if (!hasMessage) throw StateError('LSP server closed stdout');
      if (predicate(_messages.current)) return _messages.current;
    }
  }

  Future<void> dispose() async {
    await _messages.cancel();
    process.kill();
  }
}
