import 'dart:io';

import 'package:doxa_tooling/src/lsp/handler.dart';
import 'package:test/test.dart';

void main() {
  group('LspHandler document state', () {
    test('provides hover and definitions for declaration names', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/option.doxa';
      const source =
          'data Option[A: Type] : Type { none : Option A; }\n'
          'fun map{A: Type}(value: Option A) : Option A = value\n';
      handler.handle(_didOpen(uri, source));

      final optionOffset = source.indexOf('Option');
      final mapOffset = source.indexOf('map');
      final optionHover = handler.handle(
        _positionRequest(1, 'textDocument/hover', uri, optionOffset),
      );
      final mapDefinition = handler.handle(
        _positionRequest(2, 'textDocument/definition', uri, mapOffset),
      );

      expect(optionHover!['result'], isNotNull);
      expect(mapDefinition!['result'], isNotNull);
    });

    test('provides hover documentation for language built-ins', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/builtins.doxa';
      const source = 'fun identity[A: Type](value: A) : A = value\n';
      handler.handle(_didOpen(uri, source));

      final typeHover = handler.handle(
        _positionRequest(1, 'textDocument/hover', uri, source.indexOf('Type')),
      );
      final funHover = handler.handle(
        _positionRequest(2, 'textDocument/hover', uri, source.indexOf('fun')),
      );

      expect(typeHover!['result'], isNotNull);
      expect(funHover!['result'], isNotNull);
    });

    test('uses UTF-16 positions for requests after non-BMP characters', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/unicode.doxa';
      const source =
          '// 😀\ndata Option[A: Type] : Type { none : Option A; }\n';
      handler.handle(_didOpen(uri, source));

      final result = handler.handle(
        _linePositionRequest(1, 'textDocument/hover', uri, 1, 'data '.length),
      );

      expect(result!['result'], isNotNull);
    });

    test('uses Rumil token-level reparse for identifier edits', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/incremental.doxa';
      handler.handle(
        _didOpen(uri, 'fun identity[A: Type](value: A) : A = value\n'),
      );
      handler.handle(
        _didChange(
          uri,
          'fun identity[A: Type](value: A) : A = values\n',
          version: 2,
        ),
      );

      expect(handler.lastReparseStrategyFor(uri), 'tokenLevel');
    });

    test('uses Rumil declaration reparse for structural edits', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/structural.doxa';
      handler.handle(
        _didOpen(
          uri,
          'fun identity[A: Type](value: A) : A = value\n'
          'fun repeat[A: Type](value: A) : A = value\n'
          'fun keep[A: Type](value: A) : A = value\n',
        ),
      );
      handler.handle(
        _didChange(
          uri,
          'fun identity[A: Type](value: A) : A = { value }\n'
          'fun repeat[A: Type](value: A) : A = value\n'
          'fun keep[A: Type](value: A) : A = value\n',
          version: 2,
        ),
      );

      expect(handler.lastReparseStrategyFor(uri), 'blockLevel');
    });

    test('returns standard shapes for semantic tokens and formatting', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/format.doxa';
      const source = 'data Option[A: Type] : Type { none : Option A; }\n';
      handler.handle(_didOpen(uri, source));

      final tokens = handler.handle(
        _request(1, 'textDocument/semanticTokens/full', uri),
      );
      final formatting = handler.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'textDocument/formatting',
        'params': {
          'textDocument': {'uri': uri},
          'options': {'lineWidth': 100},
        },
      });

      expect(
        (tokens!['result'] as Map<String, dynamic>)['data'],
        isA<List<dynamic>>(),
      );
      expect(formatting!['result'], isA<List<dynamic>>());
      expect((formatting['result'] as List<dynamic>), isNotEmpty);
    });

    test('returns imported declaration locations from their source file', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('fun identity{A: Type}(value: A) : A = value\n');
      const source =
          'import "dependency.doxa"\nfun use{A: Type}(value: A) : A = identity value\n';
      final root = File('${directory.path}/root.doxa');
      final uri = root.uri.toString();
      final handler = LspHandler();
      handler.handle(_didOpen(uri, source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          uri,
          1,
          'fun use{A: Type}(value: A) : A = '.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], dependency.uri.toString());
      expect((location['range'] as Map<String, dynamic>)['start'], {
        'line': 0,
        'character': 'fun '.length,
      });
    });

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

Map<String, dynamic> _positionRequest(
  int id,
  String method,
  String uri,
  int character,
) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    'textDocument': {'uri': uri},
    'position': {'line': 0, 'character': character},
  },
};

Map<String, dynamic> _linePositionRequest(
  int id,
  String method,
  String uri,
  int line,
  int character,
) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    'textDocument': {'uri': uri},
    'position': {'line': line, 'character': character},
  },
};
