/// LSP transport: Content-Length framed JSON-RPC over stdin/stdout.
///
/// Reads and writes LSP messages using the standard
/// `Content-Length: N\r\n\r\n<body>` framing. No third-party
/// dependencies — plain `dart:io` + `dart:convert`.
library;

import 'dart:convert';
import 'dart:io';

/// Read one LSP message from stdin.
///
/// Returns null on EOF. Parses the `Content-Length` header, reads
/// exactly that many bytes of JSON body, and decodes it.
Map<String, dynamic>? readLspMessage() {
  // Read headers: lines until an empty line.
  int? contentLength;
  while (true) {
    final line = stdin.readLineSync();
    if (line == null) return null; // EOF
    if (line.isEmpty) break; // end of headers
    const prefix = 'Content-Length: ';
    if (line.startsWith(prefix)) {
      contentLength = int.tryParse(line.substring(prefix.length));
    }
  }

  if (contentLength == null || contentLength <= 0) return null;

  // Read exactly [contentLength] bytes of JSON body.
  final bodyBytes = <int>[];
  for (var i = 0; i < contentLength; i++) {
    final byte = stdin.readByteSync();
    bodyBytes.add(byte);
  }

  final body = utf8.decode(bodyBytes);
  return jsonDecode(body) as Map<String, dynamic>;
}

/// Send an LSP message to stdout.
///
/// Encodes [message] as JSON and writes it with the `Content-Length`
/// framing header.
void sendLspMessage(Map<String, dynamic> message) {
  final body = jsonEncode(message);
  final bytes = utf8.encode(body);
  stdout.write('Content-Length: ${bytes.length}\r\n\r\n');
  stdout.write(body);
  stdout.flush();
}
