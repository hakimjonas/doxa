/// LSP transport: Content-Length framed JSON-RPC over stdin/stdout.
///
/// Uses async I/O to avoid a known Dart runtime contention issue
/// between synchronous stdin reads and stdout writes in piped
/// processes.
library;

import 'dart:async';
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

        final header = utf8.decode(_buffer.sublist(0, termIdx));
        _buffer.removeRange(0, termIdx + 4);

        const prefix = 'Content-Length: ';
        final startIdx = header.indexOf(prefix);
        if (startIdx != -1) {
          final lenStart = startIdx + prefix.length;
          // The \r\n\r\n terminator has been stripped, so the header
          // is just the Content-Length line. Parse to end of string.
          _contentLength =
              int.tryParse(header.substring(lenStart).trim()) ?? -1;
        }
        _headerDone = true;
      }

      if (_headerDone && _contentLength > 0) {
        if (_buffer.length < _contentLength) break;

        final bodyBytes = _buffer.sublist(0, _contentLength);
        _buffer.removeRange(0, _contentLength);
        final body = utf8.decode(bodyBytes);
        _headerDone = false;
        _contentLength = -1;
        result.add(jsonDecode(body) as Map<String, dynamic>);
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
  final framed = 'Content-Length: ${body.length}\r\n\r\n$body';
  stdout.write(framed);
}
