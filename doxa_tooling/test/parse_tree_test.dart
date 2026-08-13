import 'package:doxa_tooling/src/cst.dart'
    show parseProgramCst, nodeAt, reparse;
import 'package:doxa_tooling/src/parse_tree.dart' show parseProgramTree;
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

void main() {
  group('parseProgramTree', () {
    test('produces AST and green tree', () {
      final r = parseProgramTree('val x: Type = Type');
      final pt = r.valueOrNull;
      expect(pt, isNotNull);
      expect(pt!.ast.decls, hasLength(1));
    });

    test('green tree text length matches source', () {
      final src = 'val x: Type = Type';
      final r = parseProgramTree(src);
      final pt = r.valueOrNull;
      expect(pt, isNotNull);
      expect(pt!.tree.textLength, src.length);
    });

    test('multiple declarations', () {
      final src = 'val a = b\nval c = d';
      final r = parseProgramTree(src);
      final pt = r.valueOrNull;
      expect(pt, isNotNull);
      expect(pt!.ast.decls, hasLength(2));
    });
  });

  group('parseProgramCst', () {
    test('produces RedTree that reconstructs source', () {
      final src = 'val x = y';
      final r = parseProgramCst(src);
      final red = r.valueOrNull;
      expect(red, isNotNull);
      expect(red!.text, src);
    });

    test('nodeAt returns deepest node at offset', () {
      final src = 'val x = y';
      final r = parseProgramCst(src);
      final red = r.valueOrNull!;
      final n = nodeAt(red, 4); // 'x'
      expect(n, isNotNull);
      expect(n!.text, 'x');
    });
  });

  group('incremental reparse', () {
    test('retokenizes identifier edits before using the token path', () {
      const source = 'fun identity[A: Type](value: A) : A = value\n';
      final tree = parseProgramTree(source).valueOrNull!.tree;
      final replacement = source.replaceFirst('value\n', 'fun\n');
      final edit = TextEdit(
        source.lastIndexOf('value'),
        source.length - 1,
        'fun',
      );

      final result = reparse(tree, source, edit);

      expect(result.strategy, isNot(IncrementalStrategy.tokenLevel));
      expect(result.tree.toSource(), replacement);
    });

    test('falls back when a declaration edit splits the declaration', () {
      const source = 'val a : Type = Type\nval b : Type = Type\n';
      final tree = parseProgramTree(source).valueOrNull!.tree;
      const inserted = 'val c : Type = Type\n';
      final edit = TextEdit(
        source.indexOf('\n'),
        source.indexOf('\n') + 1,
        '\n$inserted',
      );

      final result = reparse(tree, source, edit);

      expect(result.strategy, IncrementalStrategy.fullReparse);
      expect(
        result.tree.toSource(),
        'val a : Type = Type\n$inserted${source.substring(source.indexOf('val b'))}',
      );
    });
  });
}
