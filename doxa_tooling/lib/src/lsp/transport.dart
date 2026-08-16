/// LSP transport: Content-Length framed JSON-RPC over stdin/stdout.
///
/// Uses async I/O to avoid a known Dart runtime contention issue
/// between synchronous stdin reads and stdout writes in piped
/// processes.
library;

import 'dart:convert';
import 'dart:io';

/// State machine for parsing LSP messages from an async byte stream.
final class LspReader {
  final List<int> _buffer = [];
  var _headerDone = false;
  var _contentLength = -1;

  /// Feed bytes into the parser. Returns any complete messages parsed.
  List<Map<String, dynamic>> feed(List<int> bytes) {
    _buffer.addAll(bytes);
    final result = <Map<String, dynamic>>[];
    while (true) {
      if (!_headerDone) {
        final termIdx = _findHeaderTerminator(_buffer);
        if (termIdx == -1) break;

        final header = utf8.decode(
          _buffer.sublist(0, termIdx),
          allowMalformed: true,
        );
        _buffer.removeRange(0, termIdx + 4);

        _contentLength = -1;
        for (final line in header.split('\r\n')) {
          final separator = line.indexOf(':');
          if (separator < 0) continue;
          final name = line.substring(0, separator).trim().toLowerCase();
          if (name != 'content-length') continue;
          _contentLength =
              int.tryParse(line.substring(separator + 1).trim()) ?? -1;
          break;
        }
        if (_contentLength <= 0) continue;
        _headerDone = true;
      }

      if (_headerDone && _contentLength > 0) {
        if (_buffer.length < _contentLength) break;

        final bodyBytes = _buffer.sublist(0, _contentLength);
        _buffer.removeRange(0, _contentLength);
        final body = utf8.decode(bodyBytes, allowMalformed: true);
        _headerDone = false;
        _contentLength = -1;
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) result.add(decoded);
        } on FormatException {
          // A malformed frame must not terminate the long-lived server. The
          // next complete frame can still be decoded from the input stream.
        }
      } else {
        break;
      }
    }
    return result;
  }

  static int _findHeaderTerminator(List<int> bytes) {
    for (var i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// Send an LSP message to stdout.
void sendLspMessage(Map<String, dynamic> message) {
  final body = jsonEncode(message);
  final bodyBytes = utf8.encode(body);
  stdout.add(utf8.encode('Content-Length: ${bodyBytes.length}\r\n\r\n'));
  stdout.add(bodyBytes);
}
