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

    test('navigates local uses to their lexical binders', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/local-definition.doxa';
      const source =
          'fun parameter[A: Type](value: A) : A = value\n'
          'fun lambda[A: Type] : A -> A = (value: A) => value\n'
          'fun nested[A: Type](value: A) : A = { val value: A = value; value }\n'
          'fun pi[A: Type]{P: A -> Type}(x: A, value: (inner: A) -> P inner) : P x = value x\n';
      handler.handle(_didOpen(uri, source));
      final lines = source.split('\n');

      void expectDefinition(
        int line,
        int character,
        int expectedLine,
        int expectedCharacter,
      ) {
        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/definition',
            uri,
            line,
            character,
          ),
        );
        final location = result!['result'] as Map<String, dynamic>;
        expect((location['range'] as Map<String, dynamic>)['start'], {
          'line': expectedLine,
          'character': expectedCharacter,
        });
      }

      final parameter = lines[0];
      final typeParameter = parameter.indexOf('A');
      final typeParameterUse = parameter.indexOf('A', typeParameter + 1);
      expectDefinition(0, typeParameterUse, 0, typeParameter);
      final parameterDecl = parameter.indexOf('value');
      expectDefinition(0, parameter.lastIndexOf('value'), 0, parameterDecl);

      final lambda = lines[1];
      final lambdaDecl = lambda.indexOf('value');
      expectDefinition(1, lambda.lastIndexOf('value'), 1, lambdaDecl);

      final nested = lines[2];
      final functionValue = nested.indexOf('value');
      final localValue = nested.indexOf('value', functionValue + 1);
      final boundValue = nested.indexOf('value', localValue + 1);
      expectDefinition(2, boundValue, 2, functionValue);
      expectDefinition(2, nested.lastIndexOf('value'), 2, localValue);

      final pi = lines[3];
      final inner = pi.indexOf('inner');
      expectDefinition(3, pi.lastIndexOf('inner'), 3, inner);
    });

    test('provides hover documentation before semantic checking succeeds', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/keyword.doxa';
      const source = 'typeclass Broken[A: Type] { fun combine(x: A): A; }\n';
      handler.handle(_didOpen(uri, source));

      final hover = handler.handle(
        _positionRequest(
          1,
          'textDocument/hover',
          uri,
          source.indexOf('typeclass'),
        ),
      );

      expect(hover!['result'], isNotNull);
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

    test('rechecks only the changed declaration suffix', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/check-boundary.doxa';
      const source =
          'data Bool : Type { true_ : Bool; false_ : Bool; }\n'
          'val first : Bool = true_\n'
          'val second : Bool = first\n';
      const changed =
          'data Bool : Type { true_ : Bool; false_ : Bool; }\n'
          'val first : Bool = true_\n'
          'val second : Bool = false_\n';
      handler.handle(_didOpen(uri, source));
      handler.handle(_didChange(uri, changed, version: 2));

      expect(handler.lastCheckMetricsFor(uri), (
        start: 2,
        reused: 2,
        rechecked: 1,
        fallback: null,
      ));
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

    test('returns document symbol selections inside their full ranges', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/symbols.doxa';
      const source = 'fun identity[A: Type](value: A) : A = value';
      handler.handle(_didOpen(uri, source));

      final result = handler.handle(
        _request(1, 'textDocument/documentSymbol', uri),
      );

      final symbol =
          (result!['result'] as List<dynamic>).single as Map<String, dynamic>;
      final range = symbol['range'] as Map<String, dynamic>;
      final selection = symbol['selectionRange'] as Map<String, dynamic>;
      final rangeEnd = range['end'] as Map<String, dynamic>;
      final selectionEnd = selection['end'] as Map<String, dynamic>;
      expect(range['start'], {'line': 0, 'character': 0});
      expect(selection['start'], {'line': 0, 'character': 'fun '.length});
      expect(rangeEnd['line'], selectionEnd['line']);
      expect(
        rangeEnd['character'] as int,
        greaterThanOrEqualTo(selectionEnd['character'] as int),
      );
    });

    test(
      'includes constructors and excludes generated eliminators from document symbols',
      () {
        final handler = LspHandler();
        const uri = 'file:///workspace/status.doxa';
        const source =
            'data Status : Type {\n'
            '  ready : Status;\n'
            '  blocked : Status;\n'
            '}\n'
            '\n'
            'fun keep(status: Status) : Status = status\n';
        handler.handle(_didOpen(uri, source));

        final result = handler.handle(
          _request(1, 'textDocument/documentSymbol', uri),
        );

        final symbols = result!['result'] as List<dynamic>;
        expect(
          symbols.map((symbol) => (symbol as Map<String, dynamic>)['name']),
          ['Status', 'ready', 'blocked', 'keep'],
        );
      },
    );

    test('provides signature help for whitespace application', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/signature.doxa';
      const source =
          'data Status : Type {\n'
          '  ready : Status;\n'
          '  blocked : Status;\n'
          '}\n'
          '\n'
          'fun keep(status: Status) : Status = status\n'
          'fun preserve(status: Status) : Status = keep status\n';
      handler.handle(_didOpen(uri, source));

      const callPrefix = 'fun preserve(status: Status) : Status = keep ';
      for (final character in [
        callPrefix.length - 1,
        callPrefix.length,
        callPrefix.length + 6,
      ]) {
        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/signatureHelp',
            uri,
            6,
            character,
          ),
        );

        final help = result!['result'] as Map<String, dynamic>;
        final signature =
            (help['signatures'] as List<dynamic>).single
                as Map<String, dynamic>;
        expect(signature['label'], 'keep (status: Status)');
        expect(help['activeParameter'], 0);
      }
    });

    test('places declaration inlay hints after declaration names', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/nat.doxa';
      const source =
          'data Nat : Type {\n'
          '  zero : Nat;\n'
          '  succ : Nat -> Nat;\n'
          '}\n';
      handler.handle(_didOpen(uri, source));

      final result = handler.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'textDocument/inlayHint',
        'params': {
          'textDocument': {'uri': uri},
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 3, 'character': 0},
          },
        },
      });

      final hints = result!['result'] as List<dynamic>;
      expect(hints, isNotEmpty);
      expect((hints.first as Map<String, dynamic>)['position'], {
        'line': 0,
        'character': 'data Nat'.length,
      });
    });

    test('serializes reference locations as JSON maps', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/references.doxa';
      const source =
          'val identity: Type 1 = Prop\n'
          'val value: Type 1 = identity\n';
      handler.handle(_didOpen(uri, source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/references',
          uri,
          1,
          'val value: Type 1 = '.length,
        ),
      );

      expect(result!['result'], isA<List<dynamic>>());
      expect(
        (result['result'] as List<dynamic>).first,
        isA<Map<String, dynamic>>(),
      );
    });

    test('does not conflate a top-level binding with a shadowing local', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/shadowing.doxa';
      const source =
          'val x: Type 1 = Prop\n'
          'val value: Type 1 = x\n'
          'fun local(x: Type 1): Type 1 = x\n';
      handler.handle(_didOpen(uri, source));

      final topReferences = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/references',
          uri,
          0,
          'val '.length,
        ),
      );
      expect(topReferences!['result'], hasLength(2));

      final withoutDeclaration = handler.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'textDocument/references',
        'params': {
          'textDocument': {'uri': uri},
          'position': {'line': 0, 'character': 'val '.length},
          'context': {'includeDeclaration': false},
        },
      });
      expect(withoutDeclaration!['result'], hasLength(1));

      final renamed = handler.handle({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'textDocument/rename',
        'params': {
          'textDocument': {'uri': uri},
          'position': {'line': 0, 'character': 'val '.length},
          'newName': 'global',
        },
      });
      final changes =
          (renamed!['result'] as Map<String, dynamic>)['changes']
              as Map<String, dynamic>;
      expect(changes[uri], hasLength(2));

      final localUse = handler.handle(
        _linePositionRequest(
          4,
          'textDocument/prepareRename',
          uri,
          2,
          'fun local(x: Type 1): Type 1 = '.length,
        ),
      );
      expect(localUse!['result'], isNull);
    });

    test('finds local binder references without enabling local rename', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/local-references.doxa';
      const source =
          'fun nested[A: Type](status: A) : A = { val status: A = status; status }\n';
      handler.handle(_didOpen(uri, source));
      final parameter = source.indexOf('status');
      final local = source.indexOf('status', parameter + 1);
      final parameterUse = source.indexOf('status', local + 1);
      final localUse = source.lastIndexOf('status');

      int startCharacter(Object? location) {
        final range =
            (location as Map<String, dynamic>)['range'] as Map<String, dynamic>;
        final start = range['start'] as Map<String, dynamic>;
        return start['character'] as int;
      }

      List<int> referencesAt(int character, {bool includeDeclaration = true}) {
        final result = handler.handle({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'textDocument/references',
          'params': {
            'textDocument': {'uri': uri},
            'position': {'line': 0, 'character': character},
            'context': {'includeDeclaration': includeDeclaration},
          },
        });
        return [
          for (final Object? location in result!['result'] as List<dynamic>)
            startCharacter(location),
        ];
      }

      expect(
        referencesAt(parameterUse),
        unorderedEquals([parameter, parameterUse]),
      );
      expect(referencesAt(localUse), unorderedEquals([local, localUse]));
      expect(referencesAt(local), unorderedEquals([local, localUse]));
      expect(referencesAt(parameter, includeDeclaration: false), [
        parameterUse,
      ]);

      final prepared = handler.handle(
        _linePositionRequest(2, 'textDocument/prepareRename', uri, 0, local),
      );
      expect(prepared!['result'], isNull);
    });

    test('finds top-level declaration references from the declaration', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/references.doxa';
      const source =
          'fun identity{A: Type}(value: A): A = value\n'
          'fun applyIdentity(value: Type): Type = identity value\n';
      handler.handle(_didOpen(uri, source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/references',
          uri,
          0,
          source.indexOf('identity'),
        ),
      );

      expect(result!['result'], hasLength(2));
    });

    test('renames top-level declarations from either occurrence', () {
      const uri = 'file:///workspace/rename.doxa';
      const source =
          'fun identity{A: Type}(value: A): A = value\n'
          'fun applyIdentity(value: Type): Type = identity value\n';
      final declarationOffset = source.indexOf('identity');
      final referenceOffset = source.lastIndexOf('identity');
      final referenceCharacter = referenceOffset - source.indexOf('\n') - 1;

      for (final (line, character, targetCharacter) in [
        (0, declarationOffset, declarationOffset),
        (0, declarationOffset + 'identity'.length, declarationOffset),
        (1, referenceCharacter, referenceCharacter),
        (1, referenceCharacter + 'identity'.length, referenceCharacter),
      ]) {
        final handler = LspHandler();
        handler.handle(_didOpen(uri, source));
        final prepared = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/prepareRename',
            uri,
            line,
            character,
          ),
        );
        expect(prepared!['result'], {
          'start': {'line': line, 'character': targetCharacter},
          'end': {
            'line': line,
            'character': targetCharacter + 'identity'.length,
          },
        });
        final result = handler.handle({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'textDocument/rename',
          'params': {
            'textDocument': {'uri': uri},
            'position': {'line': line, 'character': character},
            'newName': 'same',
          },
        });

        final changes =
            (result!['result'] as Map<String, dynamic>)['changes']
                as Map<String, dynamic>;
        expect(changes[uri], [
          {
            'range': {
              'start': {'line': 0, 'character': declarationOffset},
              'end': {
                'line': 0,
                'character': declarationOffset + 'identity'.length,
              },
            },
            'newText': 'same',
          },
          {
            'range': {
              'start': {'line': 1, 'character': referenceCharacter},
              'end': {
                'line': 1,
                'character': referenceCharacter + 'identity'.length,
              },
            },
            'newText': 'same',
          },
        ]);
      }
    });

    test('finds and renames an imported top-level declaration', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final base = File('${directory.path}/base.doxa');
      const baseSource = 'val identity: Type 1 = Prop\n';
      base.writeAsStringSync(baseSource);
      final library = File('${directory.path}/library.doxa');
      const librarySource =
          'import "base.doxa"\n'
          'val libraryValue: Type 1 = identity\n';
      library.writeAsStringSync(librarySource);
      final app = File('${directory.path}/app.doxa');
      const appSource =
          'import "library.doxa"\n'
          'val value: Type 1 = identity\n';
      app.writeAsStringSync(appSource);
      final baseUri = base.uri.toString();
      final libraryUri = library.uri.toString();
      final appUri = app.uri.toString();
      final handler = LspHandler();
      handler.handle(_didOpen(appUri, appSource));

      final references = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/references',
          appUri,
          1,
          'val value: Type 1 = '.length,
        ),
      );
      final locations = references!['result'] as List<dynamic>;
      expect(locations, hasLength(3));
      expect(
        locations.map((location) => (location as Map<String, dynamic>)['uri']),
        containsAll(<String>[baseUri, libraryUri, appUri]),
      );

      final renamed = handler.handle({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'textDocument/rename',
        'params': {
          'textDocument': {'uri': appUri},
          'position': {'line': 1, 'character': 'val value: Type 1 = '.length},
          'newName': 'same',
        },
      });
      final changes =
          (renamed!['result'] as Map<String, dynamic>)['changes']
              as Map<String, dynamic>;
      expect(changes[baseUri], hasLength(1));
      expect(changes[libraryUri], hasLength(1));
      expect(changes[appUri], hasLength(1));
    });

    test('does not respond to notifications', () {
      final handler = LspHandler();

      expect(
        handler.handle({'jsonrpc': '2.0', 'method': 'initialized'}),
        isNull,
      );
      expect(
        handler.handle({'jsonrpc': '2.0', 'method': 'unknown/notification'}),
        isNull,
      );
      expect(handler.handle({'jsonrpc': '2.0', 'method': 'shutdown'}), isNull);
      expect(handler.handle({'jsonrpc': '2.0', 'method': 'exit'}), isNull);
    });

    test('does not advertise redundant type presentation capabilities', () {
      final handler = LspHandler();

      final result = handler.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{},
      });

      final capabilities =
          (result!['result'] as Map<String, dynamic>)['capabilities']
              as Map<String, dynamic>;
      expect(capabilities.containsKey('codeLensProvider'), isFalse);
      expect(capabilities.containsKey('inlayHintProvider'), isFalse);
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

    test(
      'returns stdlib locations for declarations used by example proofs',
      () {
        final root = File('../example/proofs.doxa').absolute;
        final source = root.readAsStringSync();
        final uri = root.uri.toString();
        final handler = LspHandler();
        handler.handle(_didOpen(uri, source));

        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/definition',
            uri,
            30,
            'val one : '.length,
          ),
        );

        expect(result!['result'], isNotNull, reason: result.toString());
        final location = result['result'] as Map<String, dynamic>;
        expect(
          location['uri'],
          File('../lib/stdlib/nat.doxa').absolute.uri.toString(),
        );
        expect((location['range'] as Map<String, dynamic>)['start'], {
          'line': 6,
          'character': 'data '.length,
        });
      },
    );

    test(
      'returns the source location for transitive imported declarations',
      () {
        final root = File('../lib/stdlib/Prop/prop.doxa').absolute;
        final source = root.readAsStringSync();
        final uri = root.uri.toString();
        final notIntro = _sourcePosition(source, 'not_intro');
        final proofsSource =
            File('../lib/stdlib/proofs.doxa').readAsStringSync();
        final falseDefinition = _sourcePosition(proofsSource, 'data False');
        final handler = LspHandler();
        handler.handle(_didOpen(uri, source));

        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/definition',
            uri,
            notIntro.line,
            notIntro.character + 'not_intro: (A -> '.length + 1,
          ),
        );

        expect(result!['result'], isNotNull, reason: result.toString());
        final location = result['result'] as Map<String, dynamic>;
        expect(
          location['uri'],
          File('../lib/stdlib/proofs.doxa').absolute.uri.toString(),
        );
        expect((location['range'] as Map<String, dynamic>)['start'], {
          'line': falseDefinition.line,
          'character': 'data '.length,
        });
      },
    );

    test(
      'semantically highlights data declarations and imported data types',
      () {
        final root = File('../lib/stdlib/Prop/prop.doxa').absolute;
        final source = root.readAsStringSync();
        final uri = root.uri.toString();
        final andDefinition = _sourcePosition(source, 'data And');
        final falseUse = _sourcePosition(source, 'not_intro: (A -> False');
        final handler = LspHandler();
        handler.handle(_didOpen(uri, source));

        final result = handler.handle(
          _request(1, 'textDocument/semanticTokens/full', uri),
        );
        final data =
            ((result!['result'] as Map<String, dynamic>)['data']
                    as List<dynamic>)
                .cast<int>();
        final tokens = _decodeSemanticTokens(data);

        expect(
          tokens,
          contains((
            line: andDefinition.line,
            character: 'data '.length,
            length: 'And'.length,
            type: 'type',
          )),
        );
        expect(
          tokens,
          contains((
            line: falseUse.line,
            character: falseUse.character + 'not_intro: (A -> '.length,
            length: 'False'.length,
            type: 'type',
          )),
        );
      },
    );

    test('returns imported constructors from their defining files', () {
      final intBase = File('../lib/stdlib/int_base.doxa').absolute;
      final intBaseSource = intBase.readAsStringSync();
      final intBaseUri = intBase.uri.toString();
      final typeclasses = File('../lib/stdlib/typeclasses.doxa').absolute;
      final typeclassesSource = typeclasses.readAsStringSync();
      final typeclassesUri = typeclasses.uri.toString();
      final handler = LspHandler();
      handler.handle(_didOpen(intBaseUri, intBaseSource));
      handler.handle(_didOpen(typeclassesUri, typeclassesSource));

      final falseDefinition = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          intBaseUri,
          70,
          '  case neg _ => '.length,
        ),
      );
      final zeroDefinition = handler.handle(
        _linePositionRequest(
          2,
          'textDocument/definition',
          typeclassesUri,
          52,
          '  fun empty() : Int = pos '.length,
        ),
      );

      expect(
        falseDefinition!['result'],
        isNotNull,
        reason: falseDefinition.toString(),
      );
      expect(
        zeroDefinition!['result'],
        isNotNull,
        reason: zeroDefinition.toString(),
      );
      final falseLocation = falseDefinition['result'] as Map<String, dynamic>;
      final zeroLocation = zeroDefinition['result'] as Map<String, dynamic>;
      expect(
        falseLocation['uri'],
        File('../lib/stdlib/bool.doxa').absolute.uri.toString(),
      );
      expect((falseLocation['range'] as Map<String, dynamic>)['start'], {
        'line': 5,
        'character': '  '.length,
      });
      expect(
        zeroLocation['uri'],
        File('../lib/stdlib/nat.doxa').absolute.uri.toString(),
      );
      expect((zeroLocation['range'] as Map<String, dynamic>)['start'], {
        'line': 7,
        'character': '  '.length,
      });
    });

    test('resolves imports through symlinked documents', () {
      final directory = Directory.systemTemp.createTempSync(
        'doxa-lsp-symlink-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final lib = Directory('${directory.path}/lib')..createSync();
      final nat = File('${lib.path}/nat.doxa')..writeAsStringSync(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n',
      );
      final sigma = Directory('${lib.path}/sigma')..createSync();
      final link = Link('${sigma.path}/entry.doxa')..createSync('../nat.doxa');
      final handler = LspHandler();
      handler.handle(_didOpen(link.uri.toString(), 'import "nat.doxa"\n'));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          link.uri.toString(),
          0,
          'import "'.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], nat.uri.toString());
    });

    test('navigates data-scope type-level names', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/sigma.doxa';
      const source =
          'data Sigma[A: Type]: (A -> Type) -> Type {\n'
          '  pair: (B: A -> Type) -> (x: A) -> B x -> Sigma A B;\n'
          '}\n';
      handler.handle(_didOpen(uri, source));
      final lines = source.split('\n');

      void expectDefinition(
        int line,
        int character,
        int expectedLine,
        int expectedCharacter,
      ) {
        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/definition',
            uri,
            line,
            character,
          ),
        );
        final location = result!['result'] as Map<String, dynamic>;
        expect(location['range'], isNotNull, reason: result.toString());
        expect((location['range'] as Map<String, dynamic>)['start'], {
          'line': expectedLine,
          'character': expectedCharacter,
        }, reason: result.toString());
      }

      final dataLine = lines[0];
      final sigmaName = dataLine.indexOf('Sigma');
      final aParam = dataLine.indexOf('A');
      final ctorLine = lines[1];
      final pairName = ctorLine.indexOf('pair');
      final bParam = ctorLine.indexOf('B');
      final xParam = ctorLine.indexOf('x');
      final aUse = ctorLine.indexOf('A', 1);
      final bUse = ctorLine.indexOf('B', bParam + 1);
      final xUse = ctorLine.indexOf('x', xParam + 1);
      final sigmaUse = ctorLine.indexOf('Sigma');

      expectDefinition(1, sigmaUse, 0, sigmaName);
      expectDefinition(1, aUse, 0, aParam);
      expectDefinition(1, bUse, 1, bParam);
      expectDefinition(1, xUse, 1, xParam);
      expectDefinition(1, pairName, 1, pairName);
      expectDefinition(0, aParam, 0, aParam);
      expectDefinition(0, sigmaName, 0, sigmaName);
    });

    test('hovers data-scope type-level names', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/sigma.doxa';
      const source =
          'data Sigma[A: Type]: (A -> Type) -> Type {\n'
          '  pair: (B: A -> Type) -> (x: A) -> B x -> Sigma A B;\n'
          '}\n';
      handler.handle(_didOpen(uri, source));
      final lines = source.split('\n');

      final ctorLine = lines[1];
      final pairName = ctorLine.indexOf('pair');
      final bUse = ctorLine.indexOf('B', 8);
      final result = handler.handle(
        _linePositionRequest(1, 'textDocument/hover', uri, 1, pairName),
      );
      expect(result!['result'], isNotNull, reason: result.toString());
      final contents =
          (result['result'] as Map<String, dynamic>)['contents'] as String;
      expect(contents, contains('pair : '));

      final binderHover = handler.handle(
        _linePositionRequest(2, 'textDocument/hover', uri, 1, bUse),
      );
      expect(binderHover!['result'], isNotNull, reason: binderHover.toString());
      final binderContents =
          (binderHover['result'] as Map<String, dynamic>)['contents'] as String;
      expect(binderContents, contains('B : A -> Type'));
    });

    test('finds type-level references inside data declarations', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/sigma-references.doxa';
      const source =
          'data Sigma[A: Type]: (A -> Type) -> Type {\n'
          '  pair: (B: A -> Type) -> (x: A) -> B x -> Sigma A B;\n'
          '}\n';
      handler.handle(_didOpen(uri, source));
      final lines = source.split('\n');

      List<(int, int)> referencesAt(
        int line,
        int character, {
        bool includeDeclaration = true,
      }) {
        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/references',
            uri,
            line,
            character,
            context: {'includeDeclaration': includeDeclaration},
          ),
        );
        return [
          for (final Object? location in result!['result'] as List<dynamic>)
            (() {
              final range =
                  (location as Map<String, dynamic>)['range']
                      as Map<String, dynamic>;
              final start = range['start'] as Map<String, dynamic>;
              return (start['line'] as int, start['character'] as int);
            })(),
        ];
      }

      final dataLine = lines[0];
      final sigmaName = dataLine.indexOf('Sigma');
      final aParam = dataLine.indexOf('A');
      final ctorLine = lines[1];
      final bParam = ctorLine.indexOf('B');
      final xParam = ctorLine.indexOf('x');
      final aUse = ctorLine.indexOf('A', 1);
      final bUse = ctorLine.indexOf('B', bParam + 1);
      final xUse = ctorLine.indexOf('x', xParam + 1);
      final sigmaUse = ctorLine.indexOf('Sigma');
      final aUse2 = ctorLine.indexOf('A', aUse + 1);
      final aUse3 = ctorLine.indexOf('A', aUse2 + 1);
      final bUse2 = ctorLine.indexOf('B', bUse + 1);

      expect(
        referencesAt(1, bParam),
        unorderedEquals([(1, bParam), (1, bUse), (1, bUse2)]),
      );
      expect(
        referencesAt(1, bUse2),
        unorderedEquals([(1, bParam), (1, bUse), (1, bUse2)]),
      );
      expect(referencesAt(1, xUse), unorderedEquals([(1, xParam), (1, xUse)]));
      expect(
        referencesAt(1, aUse3),
        unorderedEquals([
          (0, aParam),
          (0, dataLine.indexOf('A', aParam + 1)),
          (1, aUse),
          (1, aUse2),
          (1, aUse3),
        ]),
      );
      expect(
        referencesAt(1, sigmaUse),
        unorderedEquals([(0, sigmaName), (1, sigmaUse)]),
      );
      expect(
        referencesAt(0, sigmaName),
        unorderedEquals([(0, sigmaName), (1, sigmaUse)]),
      );
      expect(referencesAt(1, bParam, includeDeclaration: false), [
        (1, bUse),
        (1, bUse2),
      ]);
      expect(referencesAt(1, sigmaUse, includeDeclaration: false), [
        (1, sigmaUse),
      ]);
    });
    test('finds term-level uses of data and constructor names', () {
      final handler = LspHandler();
      const uri = 'file:///workspace/ctor-references.doxa';
      const source =
          'data Bool2: Type {\n'
          '  true2: Bool2;\n'
          '}\n'
          'data Wrap: Type {\n'
          '  w: Bool2;\n'
          '}\n'
          'fun yes(): Bool2 = true2\n';
      handler.handle(_didOpen(uri, source));
      final lines = source.split('\n');

      List<(int, int)> referencesAt(int line, int character) {
        final result = handler.handle(
          _linePositionRequest(
            1,
            'textDocument/references',
            uri,
            line,
            character,
          ),
        );
        return [
          for (final Object? location in result!['result'] as List<dynamic>)
            (() {
              final range =
                  (location as Map<String, dynamic>)['range']
                      as Map<String, dynamic>;
              final start = range['start'] as Map<String, dynamic>;
              return (start['line'] as int, start['character'] as int);
            })(),
        ];
      }

      final bool2Name = lines[0].indexOf('Bool2');
      final bool2TypeUse = lines[1].indexOf('Bool2');
      final true2Name = lines[1].indexOf('true2');
      final wrapField = lines[4].indexOf('w');
      final wrapUse = lines[4].indexOf('Bool2');
      final bool2TermUse = lines[6].indexOf('Bool2');
      final true2TermUse = lines[6].indexOf('true2');

      expect(referencesAt(4, wrapField), unorderedEquals([(4, wrapField)]));

      expect(
        referencesAt(0, bool2Name),
        unorderedEquals([
          (0, bool2Name),
          (1, bool2TypeUse),
          (4, wrapUse),
          (6, bool2TermUse),
        ]),
      );
      expect(
        referencesAt(1, bool2TypeUse),
        unorderedEquals([
          (0, bool2Name),
          (1, bool2TypeUse),
          (4, wrapUse),
          (6, bool2TermUse),
        ]),
      );
      expect(
        referencesAt(4, wrapUse),
        unorderedEquals([
          (0, bool2Name),
          (1, bool2TypeUse),
          (4, wrapUse),
          (6, bool2TermUse),
        ]),
      );
      expect(
        referencesAt(6, bool2TermUse),
        unorderedEquals([
          (0, bool2Name),
          (1, bool2TypeUse),
          (4, wrapUse),
          (6, bool2TermUse),
        ]),
      );
      expect(
        referencesAt(1, true2Name),
        unorderedEquals([(1, true2Name), (6, true2TermUse)]),
      );
      expect(
        referencesAt(6, true2TermUse),
        unorderedEquals([(1, true2Name), (6, true2TermUse)]),
      );
    });

    test('renames data declarations from type and term positions', () {
      const uri = 'file:///workspace/ctor-rename.doxa';
      const source =
          'data Bool2: Type {\n'
          '  true2: Bool2;\n'
          '}\n'
          'fun yes(): Bool2 = true2\n';
      final lines = source.split('\n');
      final bool2Name = lines[0].indexOf('Bool2');
      final bool2TypeUse = lines[1].indexOf('Bool2');
      final bool2TermUse = lines[3].indexOf('Bool2');

      final handler = LspHandler();
      handler.handle(_didOpen(uri, source));
      final prepared = handler.handle(
        _linePositionRequest(
          2,
          'textDocument/prepareRename',
          uri,
          1,
          bool2TypeUse,
        ),
      );
      expect(prepared!['result'], {
        'start': {'line': 1, 'character': bool2TypeUse},
        'end': {'line': 1, 'character': bool2TypeUse + 'Bool2'.length},
      });

      final rename = handler.handle(
        _linePositionRequest(
          2,
          'textDocument/rename',
          uri,
          1,
          bool2TypeUse,
          newName: 'Bool3',
        ),
      );
      final changes =
          (rename!['result'] as Map<String, dynamic>)['changes']
              as Map<String, dynamic>;
      final edits = changes[uri] as List<dynamic>;
      expect(edits, hasLength(3));
      expect(
        [
          for (final edit in edits)
            ((edit as Map<String, dynamic>)['range']
                as Map<String, dynamic>)['start'],
        ],
        unorderedEquals([
          {'line': 0, 'character': bool2Name},
          {'line': 1, 'character': bool2TypeUse},
          {'line': 3, 'character': bool2TermUse},
        ]),
      );

      final binderHandler = LspHandler();
      const binderSource =
          'data Sigma[A: Type]: (A -> Type) -> Type {\n'
          '  pair: (B: A -> Type) -> (x: A) -> B x -> Sigma A B;\n'
          '}\n';
      binderHandler.handle(
        _didOpen('file:///workspace/binder.doxa', binderSource),
      );
      final binderPrepare = binderHandler.handle(
        _linePositionRequest(
          2,
          'textDocument/prepareRename',
          'file:///workspace/binder.doxa',
          1,
          binderSource.split('\n')[1].indexOf('B'),
        ),
      );
      expect(binderPrepare!['result'], isNull);
    });

    test('returns imported files for import declarations', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('data Dependency : Type {}\n');
      final root = File('${directory.path}/root.doxa');
      const source = 'import "dependency.doxa"\n';
      final handler = LspHandler();
      handler.handle(_didOpen(root.uri.toString(), source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          root.uri.toString(),
          0,
          'import "'.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], dependency.uri.toString());
      expect((location['range'] as Map<String, dynamic>)['start'], {
        'line': 0,
        'character': 0,
      });
    });

    test('returns import targets before the document type-checks', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('data Dependency : Type {}\n');
      final root = File('${directory.path}/root.doxa');
      const source =
          'import "dependency.doxa"\nval broken : Missing = missing\n';
      final handler = LspHandler();
      handler.handle(_didOpen(root.uri.toString(), source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          root.uri.toString(),
          0,
          'import "'.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], dependency.uri.toString());
    });

    test('returns import targets after a later parse failure', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('data Dependency : Type {}\n');
      final root = File('${directory.path}/root.doxa');
      const source = 'import "dependency.doxa"\nval broken : Dependency =\n';
      final handler = LspHandler();
      handler.handle(_didOpen(root.uri.toString(), source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          root.uri.toString(),
          0,
          'import "'.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], dependency.uri.toString());
    });

    test('resolves constructors with multiple imported source files', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final bool = File('${directory.path}/bool.doxa')..writeAsStringSync(
        'data Bool : Type { true_ : Bool; false_ : Bool; }\n',
      );
      File('${directory.path}/nat.doxa').writeAsStringSync(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }\n',
      );
      final root = File('${directory.path}/typeclasses.doxa');
      const source =
          'import "bool.doxa"\n'
          'import "nat.doxa"\n'
          'fun choose(n: Nat) : Bool = match n {\n'
          '  case zero => false_\n'
          '  case succ _ => true_\n'
          '}\n';
      final handler = LspHandler();
      handler.handle(_didOpen(root.uri.toString(), source));

      final result = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          root.uri.toString(),
          3,
          '  case zero => '.length,
        ),
      );

      expect(result!['result'], isNotNull, reason: result.toString());
      final location = result['result'] as Map<String, dynamic>;
      expect(location['uri'], bool.uri.toString());
    });

    test('checks the standard-library prelude without ambient duplicates', () {
      final prelude = File('../lib/stdlib/prelude.doxa').absolute;
      final handler = LspHandler();
      handler.handle(
        _didOpen(prelude.uri.toString(), prelude.readAsStringSync()),
      );

      final result = handler.handle(
        _request(1, 'textDocument/semanticTokens/full', prelude.uri.toString()),
      );

      expect(result!['result'], isA<Map<String, dynamic>>());
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

    test('watched imports invalidate only dependent sessions', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('data One : Type { one : One; }');
      final dependentUri =
          File('${directory.path}/dependent.doxa').uri.toString();
      const independentUri = 'file:///workspace/independent.doxa';
      final handler = LspHandler();
      handler.handle(
        _didOpen(dependentUri, 'import "dependency.doxa"\nval x : One = one\n'),
      );
      handler.handle(_didOpen(independentUri, 'val x : Type = Type\n'));
      handler.handle(
        _didChange(independentUri, 'val x : Type = Type\n', version: 2),
      );

      dependency.writeAsStringSync('data Two : Type { two : Two; }');
      handler.handle({
        'jsonrpc': '2.0',
        'method': 'workspace/didChangeWatchedFiles',
        'params': {
          'changes': [
            {'uri': dependency.uri.toString(), 'type': 2},
          ],
        },
      });

      expect(
        handler.lastCheckMetricsFor(dependentUri)!.fallback,
        'initial_check',
      );
      expect(handler.lastCheckMetricsFor(independentUri)!.fallback, isNull);
    });

    test('recovers after sequential watched import edits', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final base = File('${directory.path}/base.doxa')
        ..writeAsStringSync('val identity: Type 1 = Prop\n');
      final library = File('${directory.path}/library.doxa')..writeAsStringSync(
        'import "base.doxa"\n'
        'val libraryValue: Type 1 = identity\n',
      );
      final app = File('${directory.path}/app.doxa');
      const appSource =
          'import "library.doxa"\n'
          'val value: Type 1 = identity\n';
      const renamedAppSource =
          'import "library.doxa"\n'
          'val value: Type 1 = same\n';
      final appUri = app.uri.toString();
      final handler = LspHandler();
      handler.handle(_didOpen(appUri, appSource));

      // A workspace edit can expose an intermediate import graph in which the
      // definition has changed before uses in dependent files are updated.
      handler.handle(_didChange(appUri, renamedAppSource, version: 2));
      base.writeAsStringSync('val same: Type 1 = Prop\n');
      handler.handle(_watchedFileChange(base.uri.toString()));
      library.writeAsStringSync(
        'import "base.doxa"\n'
        'val libraryValue: Type 1 = same\n',
      );
      handler.handle(_watchedFileChange(library.uri.toString()));

      final definition = handler.handle(
        _linePositionRequest(
          1,
          'textDocument/definition',
          appUri,
          1,
          'val value: Type 1 = '.length,
        ),
      );
      expect(definition!['result'], isNotNull, reason: definition.toString());
      expect(
        (definition['result'] as Map<String, dynamic>)['uri'],
        base.uri.toString(),
      );
    });

    test('open imported documents override disk contents for dependents', () {
      final directory = Directory.systemTemp.createTempSync('doxa-lsp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final dependency = File('${directory.path}/dependency.doxa')
        ..writeAsStringSync('data One : Type { one : One; }');
      final dependent = File('${directory.path}/dependent.doxa');
      final dependentUri = dependent.uri.toString();
      final dependencyUri = dependency.uri.toString();
      final handler = LspHandler();
      handler.handle(
        _didOpen(dependentUri, 'import "dependency.doxa"\nval x : One = one\n'),
      );

      handler.handle(_didOpen(dependencyUri, 'data Two : Type { two : Two; }'));

      final definition = handler.handle(
        _linePositionRequest(1, 'textDocument/definition', dependentUri, 1, 8),
      );
      expect(definition!['result'], isNull);
      expect(
        handler.lastCheckMetricsFor(dependentUri)!.fallback,
        'initial_check',
      );

      handler.handle({
        'jsonrpc': '2.0',
        'method': 'textDocument/didClose',
        'params': {
          'textDocument': {'uri': dependencyUri},
        },
      });
      final restored = handler.handle(
        _linePositionRequest(2, 'textDocument/definition', dependentUri, 1, 8),
      );
      expect(restored!['result'], isNotNull);
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

Map<String, dynamic> _watchedFileChange(String uri) => {
  'jsonrpc': '2.0',
  'method': 'workspace/didChangeWatchedFiles',
  'params': {
    'changes': [
      {'uri': uri, 'type': 2},
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
  int character, {
  Map<String, dynamic>? context,
  String? newName,
}) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  'params': {
    'textDocument': {'uri': uri},
    'position': {'line': line, 'character': character},
    if (context != null) 'context': context,
    if (newName != null) 'newName': newName,
  },
};

({int line, int character}) _sourcePosition(String source, String text) {
  final offset = source.indexOf(text);
  if (offset < 0) throw StateError('Could not find "$text" in source');
  final prefix = source.substring(0, offset);
  final line = '\n'.allMatches(prefix).length;
  return (line: line, character: offset - prefix.lastIndexOf('\n') - 1);
}

List<({int line, int character, int length, String type})>
_decodeSemanticTokens(List<int> data) {
  const legend = [
    'type',
    'class',
    'enumMember',
    'variable',
    'function',
    'method',
    'parameter',
    'property',
    'keyword',
    'modifier',
    'namespace',
    'comment',
    'number',
    'string',
    'operator',
  ];
  var line = 0;
  var character = 0;
  final result = <({int line, int character, int length, String type})>[];
  for (var i = 0; i < data.length; i += 5) {
    line += data[i];
    character = data[i] == 0 ? character + data[i + 1] : data[i + 1];
    result.add((
      line: line,
      character: character,
      length: data[i + 2],
      type: legend[data[i + 3]],
    ));
  }
  return result;
}
