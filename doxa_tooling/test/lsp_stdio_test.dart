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

      final diagnostics = await server.nextMessage();
      expect(diagnostics['method'], 'textDocument/publishDiagnostics');
      expect((diagnostics['params'] as Map<String, dynamic>)['uri'], uri);
      expect((diagnostics['params'] as Map<String, dynamic>)['version'], 7);
      expect(
        (diagnostics['params'] as Map<String, dynamic>)['diagnostics'],
        isNotEmpty,
      );

      server.send({'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown'});
      expect(await server.nextMessage(), {
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

        final notification = await server.nextMessage();
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
  });
}

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

  Future<Map<String, dynamic>> nextMessage() async {
    final hasMessage = await _messages.moveNext().timeout(
      const Duration(seconds: 10),
    );
    if (!hasMessage) throw StateError('LSP server closed stdout');
    return _messages.current;
  }

  Future<void> dispose() async {
    await _messages.cancel();
    process.kill();
  }
}
