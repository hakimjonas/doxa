import 'package:doxa/src/source.dart';
import 'package:doxa/src/surface.dart';
import 'package:test/test.dart';

void main() {
  group('positionAt', () {
    test('single-line source', () {
      final s = SourceFile(filename: 'f', text: 'hello');
      expect(s.positionAt(0), (line: 1, column: 1));
      expect(s.positionAt(3), (line: 1, column: 4));
      expect(s.positionAt(5), (line: 1, column: 6));
    });

    test('multi-line source', () {
      // Line 1: "ab" (offsets 0-1, \n at 2)
      // Line 2: "cd" (offsets 3-4, \n at 5)
      // Line 3: "ef" (offsets 6-7)
      final s = SourceFile(filename: 'f', text: 'ab\ncd\nef');
      expect(s.positionAt(0), (line: 1, column: 1));
      expect(s.positionAt(1), (line: 1, column: 2));
      expect(s.positionAt(2), (line: 1, column: 3)); // newline itself
      expect(s.positionAt(3), (line: 2, column: 1));
      expect(s.positionAt(4), (line: 2, column: 2));
      expect(s.positionAt(6), (line: 3, column: 1));
      expect(s.positionAt(7), (line: 3, column: 2));
    });

    test('offset past end of text is clamped', () {
      final s = SourceFile(filename: 'f', text: 'ab');
      final pos = s.positionAt(100);
      expect(pos.line, 1);
      // Clamped to offset 2, column = 2 - 0 + 1 = 3.
      expect(pos.column, 3);
    });

    test('negative offset returns start', () {
      final s = SourceFile(filename: 'f', text: 'ab');
      expect(s.positionAt(-1), (line: 1, column: 1));
    });
  });

  group('lineAt', () {
    test('multi-line', () {
      final s = SourceFile(filename: 'f', text: 'first\nsecond\nthird');
      expect(s.lineAt(0), 'first');
      expect(s.lineAt(6), 'second');
      expect(s.lineAt(13), 'third');
    });

    test('CRLF line endings', () {
      final s = SourceFile(filename: 'f', text: 'a\r\nb');
      expect(s.lineAt(0), 'a');
      expect(s.lineAt(3), 'b');
    });
  });

  group('formatStart', () {
    test('normal span', () {
      final s = SourceFile(filename: 'input.doxa', text: 'val x = y');
      const span = DoxaSpan(8, 9);
      expect(s.formatStart(span), 'input.doxa:1:9');
    });

    test('synthetic span', () {
      final s = SourceFile(filename: 'input.doxa', text: 'val x = y');
      expect(s.formatStart(DoxaSpan.synthetic), 'input.doxa:<synthesized>');
    });
  });
}
