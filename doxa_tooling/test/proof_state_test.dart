import 'package:doxa_tooling/src/lsp/handler.dart';
import 'package:test/test.dart';

void main() {
  group('doxa/proofState notification', () {
    test('sends open goals with context and target after didOpen', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/proof.doxa';
      const source = 'val f : (A: Type) -> A -> A = by { intro A }\n';
      handler.handle(_didOpen(uri, source));

      final proofStates = _proofStates(notifications);
      expect(proofStates, hasLength(1));
      final params = proofStates.single['params'] as Map<String, dynamic>;
      expect(params['uri'], uri);
      expect(params['version'], 0);

      final blocks = params['blocks'] as List<dynamic>;
      expect(blocks, hasLength(1));
      final block = blocks.single as Map<String, dynamic>;
      expect(block['solved'], false);
      // The span covers `by { ... }` plus trailing whitespace, per the
      // parser's atom-span convention (end = next token or EOF). An
      // end at the document's trailing newline decodes to the next
      // line's start, like every other server position.
      expect(block['span'], {
        'start': {'line': 0, 'character': source.indexOf('by')},
        'end': {'line': 1, 'character': 0},
      });

      final goals = block['goals'] as List<dynamic>;
      expect(goals, hasLength(1));
      final goal = goals.single as Map<String, dynamic>;
      expect(goal['context'], [
        {'name': 'A', 'type': 'Type'},
      ]);
      expect(goal['target'], 'A -> A');
    });

    test('reports a fully proved block as solved with no goals', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/proved.doxa';
      const source =
          'val id : (A: Type) -> A -> A = by { intro A; intro x; exact x }\n';
      handler.handle(_didOpen(uri, source));

      final proofStates = _proofStates(notifications);
      expect(proofStates, hasLength(1));
      final blocks =
          (proofStates.single['params'] as Map<String, dynamic>)['blocks']
              as List<dynamic>;
      final block = blocks.single as Map<String, dynamic>;
      expect(block['solved'], true);
      expect(block['goals'], isEmpty);
    });

    test('sends an empty block list for documents without by blocks', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/plain.doxa';
      const source = 'val one : Type = Type\n';
      handler.handle(_didOpen(uri, source));

      final proofStates = _proofStates(notifications);
      expect(proofStates, hasLength(1));
      final blocks =
          (proofStates.single['params'] as Map<String, dynamic>)['blocks']
              as List<dynamic>;
      expect(blocks, isEmpty);
    });

    test('keeps goal state current across didChange rechecks', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/proof.doxa';
      const opened = 'val f : (A: Type) -> A -> A = by { intro A }\n';
      const changed =
          'val id : (A: Type) -> A -> A = by { intro A; intro x; exact x }\n';
      handler.handle(_didOpen(uri, opened));
      handler.handle(_didChange(uri, changed, version: 2));

      final proofStates = _proofStates(notifications);
      expect(proofStates, hasLength(2));
      final second = proofStates.last['params'] as Map<String, dynamic>;
      expect(second['version'], 2);
      final blocks = second['blocks'] as List<dynamic>;
      final block = blocks.single as Map<String, dynamic>;
      expect(block['solved'], true);
    });

    test('uses UTF-16 positions in spans after non-BMP characters', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/unicode-proof.doxa';
      const source = '// 😀\nval f : (A: Type) -> A -> A = by { intro A }\n';
      handler.handle(_didOpen(uri, source));

      final proofStates = _proofStates(notifications);
      final block =
          ((proofStates.single['params'] as Map<String, dynamic>)['blocks']
                      as List<dynamic>)
                  .single
              as Map<String, dynamic>;
      final span = block['span'] as Map<String, dynamic>;
      // Line 1 (0-based); the emoji occupies two UTF-16 code units but
      // sits on the comment line, so block positions match code points
      // of line 1 directly.
      expect((span['start'] as Map<String, dynamic>)['line'], 1);
      expect(
        (span['start'] as Map<String, dynamic>)['character'],
        source.indexOf('by') - source.indexOf('\n') - 1,
      );
    });

    test('reports goals for a block whose alternative failed', () {
      final handler = LspHandler();
      final notifications = <Map<String, dynamic>>[];
      handler.onNotification = notifications.add;
      const uri = 'file:///workspace/failed.doxa';
      const source = 'val g : (A: Type) -> A -> A = by { intro A; trivial }\n';
      handler.handle(_didOpen(uri, source));

      final proofStates = _proofStates(notifications);
      expect(proofStates, hasLength(1));
      final blocks =
          (proofStates.single['params'] as Map<String, dynamic>)['blocks']
              as List<dynamic>;
      final block = blocks.single as Map<String, dynamic>;
      expect(block['solved'], false);
      final goals = block['goals'] as List<dynamic>;
      expect(goals, isNotEmpty);
      // The open goal is the codomain after intro: `A -> A` under `A`.
      final goal = goals.first as Map<String, dynamic>;
      expect(goal['context'], [
        {'name': 'A', 'type': 'Type'},
      ]);
      expect(goal['target'], 'A -> A');
    });
  });
}

List<Map<String, dynamic>> _proofStates(
  List<Map<String, dynamic>> notifications,
) => [
  for (final notification in notifications)
    if (notification['method'] == 'doxa/proofState') notification,
];

Map<String, dynamic> _didOpen(String uri, String text) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/didOpen',
  'params': {
    'textDocument': {
      'uri': uri,
      'languageId': 'doxa',
      'version': 0,
      'text': text,
    },
  },
};

Map<String, dynamic> _didChange(String uri, String text, {int? version}) => {
  'jsonrpc': '2.0',
  'method': 'textDocument/didChange',
  'params': {
    'textDocument': {'uri': uri, 'version': version},
    'contentChanges': [
      {'text': text},
    ],
  },
};
