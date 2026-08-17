import 'package:doxa_tooling/src/lsp/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('serializes folding range characters without a kind', () {
    const range = LspFoldingRange(
      startLine: 1,
      endLine: 3,
      startCharacter: 2,
      endCharacter: 4,
    );

    expect(range.toJson(), {
      'startLine': 1,
      'endLine': 3,
      'startCharacter': 2,
      'endCharacter': 4,
    });
  });
}
