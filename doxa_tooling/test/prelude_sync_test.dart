/// The ambient prelude is a hard-coded mirror of `doxa_stdlib/lib/stdlib/prelude.doxa`
/// (`preludeSource` in `package:doxa/src/prelude.dart`). This test keeps
/// the two sources structurally in sync: the embedded Eq and Acc must
/// elaborate to the same data declarations as the file.
library;

import 'dart:io';

import 'package:doxa/src/elab.dart';
import 'package:doxa/src/parse.dart';
import 'package:doxa/src/prelude.dart';
import 'package:doxa/src/surface.dart';
import 'package:rumil/rumil.dart';
import 'package:test/test.dart';

SProgram _parse(String src) {
  final r = parseProgram(src);
  if (r is Success<ParseError, SProgram>) return r.value;
  if (r is Partial<ParseError, SProgram>) return r.value;
  fail('parse failed: $r');
}

List<DataDecl> _dataDecls(String src) => elabProgram(_parse(src)).dataDecls;

/// Compare the parts of a [DataDecl] that carry meaning. Names are
/// diagnostic hints, so only the declared name, telescope types, sort,
/// and constructor shapes are compared.
void _expectSameData(DataDecl expected, DataDecl actual, String where) {
  expect(actual.name, expected.name, reason: '$where name');
  expect(
    actual.params.length,
    expected.params.length,
    reason: '$where param count',
  );
  for (var i = 0; i < expected.params.length; i++) {
    expect(
      actual.params[i].type,
      expected.params[i].type,
      reason: '$where param $i type',
    );
  }
  expect(
    actual.indices.length,
    expected.indices.length,
    reason: '$where index count',
  );
  for (var i = 0; i < expected.indices.length; i++) {
    expect(
      actual.indices[i].type,
      expected.indices[i].type,
      reason: '$where index $i type',
    );
  }
  expect(actual.sort, expected.sort, reason: '$where sort');
  expect(
    actual.ctors.length,
    expected.ctors.length,
    reason: '$where ctor count',
  );
  for (var c = 0; c < expected.ctors.length; c++) {
    final ec = expected.ctors[c];
    final ac = actual.ctors[c];
    expect(ac.name, ec.name, reason: '$where ctor $c name');
    expect(ac.args.length, ec.args.length, reason: '$where ${ec.name} arity');
    for (var a = 0; a < ec.args.length; a++) {
      expect(
        ac.args[a].type,
        ec.args[a].type,
        reason: '$where ${ec.name} arg $a type',
      );
    }
    expect(
      ac.resultIndices,
      ec.resultIndices,
      reason: '$where ${ec.name} result indices',
    );
  }
}

void main() {
  final embedded = _dataDecls(preludeSource);
  final fromFile = _dataDecls(
    File('../doxa_stdlib/lib/stdlib/prelude.doxa').readAsStringSync(),
  );

  test('embedded prelude matches doxa_stdlib/lib/stdlib/prelude.doxa', () {
    for (final name in ['Eq', 'Acc']) {
      _expectSameData(
        embedded.firstWhere((d) => d.name == name),
        fromFile.firstWhere((d) => d.name == name),
        name,
      );
    }
  });

  test('Acc is parameterized by the relation', () {
    final acc = embedded.firstWhere((d) => d.name == 'Acc');
    expect(acc.params, hasLength(2));
    expect(acc.indices, hasLength(1));
    expect(acc.ctors, hasLength(1));
    expect(acc.ctors.single.name, 'acc_intro');
    expect(acc.ctors.single.args, hasLength(2));
  });
}
