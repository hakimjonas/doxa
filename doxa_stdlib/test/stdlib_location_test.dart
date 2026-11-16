/// The packaged standard library resolves through the package
/// configuration and type-checks with the Doxa CLI.
///
/// The test drives the CLI from the sibling `doxa_tooling/` checkout when
/// one is present. A standalone copy of the package has no checker, so the
/// check test is skipped there; the package itself declares no dependency
/// on the kernel or the tooling.
library;

import 'dart:io';

import 'package:doxa_stdlib/doxa_stdlib.dart';
import 'package:test/test.dart';

void main() {
  test('the packaged stdlib root resolves and holds the sources', () {
    final root = Directory(stdlibRootPath);
    expect(
      root.existsSync(),
      isTrue,
      reason: 'stdlibRootPath does not exist: $stdlibRootPath',
    );
    for (final name in [
      'nat.doxa',
      'bool.doxa',
      'proofs.doxa',
      'prelude.doxa',
    ]) {
      expect(
        File('$stdlibRootPath/$name').existsSync(),
        isTrue,
        reason: 'missing $stdlibRootPath/$name',
      );
    }
    expect(
      File('$stdlibRootPath/Nat/package.doxa').existsSync(),
      isTrue,
      reason: 'missing Nat/package.doxa re-export',
    );
  });

  test('the checker accepts a stdlib file through the packaged root', () async {
    final checker = File('../doxa_tooling/bin/doxa.dart');
    if (!checker.existsSync()) {
      markTestSkipped(
        'standalone package checkout: ../doxa_tooling/bin/doxa.dart is '
        'not present',
      );
      return;
    }
    final target = '$stdlibRootPath/nat.doxa';
    final result = await Process.run(Platform.resolvedExecutable, [
      checker.path,
      'check',
      target,
    ]);
    expect(
      result.exitCode,
      0,
      reason:
          'doxa check $target failed\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
    );
  });
}
