/// A version tag builds the GitHub release and nothing else. Every external
/// publish is a manual dispatch with a typed confirmation and a repository
/// variable that is unset by default. This test is the guard `AGENTS.md`
/// describes in its publishing section.
library;

import 'dart:io';

import 'package:test/test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final release = _read('../.github/workflows/release.yml');
  final publish = _read('../.github/workflows/publish.yml');

  test('release.yml triggers on a version tag and nothing else', () {
    expect(release, contains("tags: ['v*']"));
    expect(release, isNot(contains('workflow_dispatch')));
  });

  test('release.yml publishes nothing external', () {
    for (final forbidden in [
      'dart pub publish',
      'vsce publish',
      'publishPlugin',
      'pana',
      'id-token',
      'secrets.',
    ]) {
      expect(release, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('release.yml still produces the GitHub release', () {
    expect(release, contains('softprops/action-gh-release'));
    expect(release, contains('checksums.txt'));
    expect(release, contains('Check VERSION matches the tag'));
  });

  test('publish.yml is manual only', () {
    expect(publish, contains('workflow_dispatch:'));
    expect(publish, isNot(contains('push:')));
  });

  test('publish.yml carries the confirmation and hold gates', () {
    expect(publish, contains(r'if [ "${CONFIRM:-}" != "PUBLISH" ]'));
    expect(
      publish,
      contains(r'ALLOW_PUB_DEV: ${{ vars.ALLOW_PUB_DEV_PUBLISH }}'),
    );
    expect(
      publish,
      contains(r'ALLOW_MARKETPLACE: ${{ vars.ALLOW_MARKETPLACE_PUBLISH }}'),
    );
    expect(RegExp(r'needs: \[preflight\]').allMatches(publish).length, 3);
  });

  test('neither workflow rewrites or deletes a tag', () {
    for (final workflow in [release, publish]) {
      expect(workflow, isNot(contains('git push origin :refs/tags')));
      expect(workflow, isNot(contains('--force-with-lease')));
    }
  });

  test('publish.yml dogfoods lam', () {
    expect(publish, contains('dart pub global activate lambe 0.14.0'));
    expect(publish, contains('lam -r'));
    expect(RegExp(r'\bjq\b').hasMatch(publish), isFalse);
  });
}
