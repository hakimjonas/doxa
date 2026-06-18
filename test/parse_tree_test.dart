import 'package:doxa/src/cst.dart' show parseProgramCst, nodeAt, toSource;
import 'package:doxa/src/parse_tree.dart' show parseProgramTree;
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
}
