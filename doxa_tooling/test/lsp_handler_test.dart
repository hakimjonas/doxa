import 'package:doxa_tooling/src/lsp/handler.dart';
import 'package:test/test.dart';

void main() {
  group('LspHandler document state', () {
    test('serves interleaved requests from their requested document', () {
      final handler = LspHandler();
      const firstUri = 'file:///workspace/first.doxa';
      const secondUri = 'file:///workspace/second.doxa';

      handler.handle(
        _didOpen(
          firstUri,
          'import "a.doxa"\nimport "b.doxa"\nval first : Type = Type\n',
        ),
      );
      handler.handle(_didOpen(secondUri, 'val second : Type = Type\n'));

      final firstFolds = handler.handle(
        _request(1, 'textDocument/foldingRange', firstUri),
      );
      final secondFolds = handler.handle(
        _request(2, 'textDocument/foldingRange', secondUri),
      );

      expect(firstFolds!['result'], isA<List<dynamic>>());
      expect(firstFolds['result'], isNotEmpty);
      expect(secondFolds!['result'], isEmpty);
    });

    test('ignores out-of-order document changes', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/versioned.doxa';

      handler.handle(
        _didOpen(uri, 'import "a.doxa"\nimport "b.doxa"\n', version: 1),
      );
      handler.handle(
        _didChange(uri, 'val current : Type = Type\n', version: 2),
      );
      handler.handle(
        _didChange(uri, 'import "a.doxa"\nimport "b.doxa"\n', version: 1),
      );

      final folds = handler.handle(
        _request(1, 'textDocument/foldingRange', uri),
      );
      expect(folds!['result'], isEmpty);
    });

    test('closing one document preserves other open documents', () {
      final handler = LspHandler();
      const firstUri = 'file:///workspace/first.doxa';
      const secondUri = 'file:///workspace/second.doxa';

      handler.handle(_didOpen(firstUri, 'val first : Type = Type\n'));
      handler.handle(_didOpen(secondUri, 'val second : Type = Type\n'));
      handler.handle({
        'jsonrpc': '2.0',
        'method': 'textDocument/didClose',
        'params': {
          'textDocument': {'uri': firstUri},
        },
      });

      final closed = handler.handle(
        _request(1, 'textDocument/foldingRange', firstUri),
      );
      final open = handler.handle(
        _request(2, 'textDocument/foldingRange', secondUri),
      );

      final error = closed!['error'] as Map<String, dynamic>;
      expect(error['code'], -32602);
      expect(open!['result'], isEmpty);
    });
  });
}

Map<String, dynamic> _didOpen(String uri, String text, {int version = 1}) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/didOpen',
  'params': {
    'textDocument': {
      'uri': uri,
      'languageId': 'doxa',
      'version': version,
      'text': text,
    },
  },
};

Map<String, dynamic> _didChange(
  String uri,
  String text, {
  required int version,
}) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/didChange',
  'params': {
    'textDocument': {'uri': uri, 'version': version},
    'contentChanges': [
      {'text': text},
    ],
  },
};

Map<String, dynamic> _request(int id, String method, String uri) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    'textDocument': {'uri': uri},
  },
};
