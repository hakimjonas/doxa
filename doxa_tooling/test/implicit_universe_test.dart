/// The public check path rejects a universe-mismatched implicit solution
/// at the application, with the same diagnostic kind as the direct form.
library;

import 'package:doxa_tooling/src/output.dart';
import 'package:doxa_tooling/src/web_check.dart';
import 'package:test/test.dart';

const _identity = 'fun identity{A: Type}(value: A): A = value\n';

CheckError _singleError(String src) {
  final output = checkSourceOutput(src);
  expect(output, isA<CheckFailure>());
  final errors = (output as CheckFailure).errors;
  expect(errors, hasLength(1));
  return errors.single;
}

void main() {
  group('implicit-universe diagnostics', () {
    test('the indirect form fails at the application with Type/Type 1', () {
      const called = 'fun applyIdentity(value: Type): Type = identity value\n';
      const src = '$_identity$called';
      final error = _singleError(src);
      expect(error.kind, 'type_mismatch');
      expect(error.expected, 'Type');
      expect(error.actual, 'Type 1');
      expect(error.line, 2);
      // The caret lands on the argument that constrained the implicit,
      // not on the declaration heading.
      final argumentOffset = src.indexOf('identity ') + 'identity '.length;
      expect(error.span?.start, argumentOffset);
      expect(error.message, isNot(contains('solved metavariable')));
    });

    test('the direct form keeps the same kind and detail', () {
      const src = 'val direct: (value: Type) -> Type = (value: Type) => Type\n';
      final error = _singleError(src);
      expect(error.kind, 'type_mismatch');
      expect(error.expected, 'Type');
      expect(error.actual, 'Type 1');
    });

    test('a well-typed implicit call still checks', () {
      const src =
          '$_identity'
          'fun applyIdentity{B: Type}(value: B): B = identity value\n';
      final output = checkSourceOutput(src);
      expect(output, isA<CheckSuccess>());
    });
  });
}
