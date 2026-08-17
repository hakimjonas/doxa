import 'dart:convert';

import 'package:doxa_tooling/src/lsp/transport.dart';
import 'package:test/test.dart';

void main() {
  test('reads framed messages with additional headers', () {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialized'});
    final reader = LspReader();

    final messages = reader.feed(
      utf8.encode(
        'Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n'
        'content-length: ${utf8.encode(body).length}\r\n'
        '\r\n'
        '$body',
      ),
    );

    expect(messages, [
      {'jsonrpc': '2.0', 'method': 'initialized'},
    ]);
  });

  test('skips malformed JSON frames and reads the following frame', () {
    final valid = jsonEncode({'jsonrpc': '2.0', 'method': 'initialized'});
    final reader = LspReader();

    final messages = reader.feed(
      utf8.encode(
        'Content-Length: 1\r\n\r\n{'
        'Content-Length: ${utf8.encode(valid).length}\r\n\r\n$valid',
      ),
    );

    expect(messages, [
      {'jsonrpc': '2.0', 'method': 'initialized'},
    ]);
  });
}
