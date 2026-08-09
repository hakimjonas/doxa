/// REPL session tests: :browse, :search, and basic meta-commands.
library;

import 'package:test/test.dart';
import 'package:doxa_tooling/src/repl.dart';

void main() {
  group('REPL :browse and :search', () {
    test(':browse on empty session shows nothing', () {
      final session = ReplSession();
      final (result, _) = session.processInput(':browse');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, isEmpty);
    });

    test(':browse after adding declarations shows names', () {
      var session = ReplSession();
      // Add a data declaration.
      var (_, next) = session.processInput(
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
      );
      session = next;
      // Add a val.
      (_, next) = session.processInput('val x : Bool = true_');
      session = next;

      final (result, _) = session.processInput(':browse');
      expect(result, isA<ReplMeta>());
      final text = (result as ReplMeta).text;
      expect(text, contains('true_ : Bool'));
      expect(text, contains('false_ : Bool'));
      expect(text, contains('Bool : Type (data, 2 ctors)'));
      expect(text, contains('x : Bool'));
    });

    test(':search filters by substring', () {
      var session = ReplSession();
      var (_, next) = session.processInput(
        'data Bool : Type { true_ : Bool; false_ : Bool; }',
      );
      session = next;

      final (result, _) = session.processInput(':search true');
      expect(result, isA<ReplMeta>());
      final text = (result as ReplMeta).text;
      // :search matches both name and type, so Bool.ind and Bool.rec
      // appear (their types mention true_) alongside the constructor.
      expect(text, contains('true_'));
      expect(text, contains('Bool.ind'));
      expect(text, contains('Bool.rec'));
      // Searching for a nonexistent substring returns nothing.
      final (result2, _) = session.processInput(':search nonexistent_xyz');
      final text2 = (result2 as ReplMeta).text;
      expect(text2, isEmpty);
    });

    test(':search is case-insensitive', () {
      var session = ReplSession();
      var (_, next) = session.processInput(
        'data Nat : Type { zero : Nat; succ : Nat -> Nat; }',
      );
      session = next;

      final (result, _) = session.processInput(':search NAT');
      expect(result, isA<ReplMeta>());
      final text = (result as ReplMeta).text;
      expect(text, contains('Nat'));
    });

    test(':search with no matches returns empty', () {
      final session = ReplSession();
      final (result, _) = session.processInput(':search nonexistent');
      expect(result, isA<ReplMeta>());
      expect((result as ReplMeta).text, isEmpty);
    });
  });
}
