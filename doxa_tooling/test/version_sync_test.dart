/// The canonical version lives in `VERSION`. Every package and editor
/// mirror must match it. This test is the guard the release section of
/// `AGENTS.md` assumes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _read(String path) => File(path).readAsStringSync();

String _firstMatch(String text, RegExp pattern, String path) {
  final m = pattern.firstMatch(text);
  if (m == null) {
    fail('no version match in $path for ${pattern.pattern}');
  }
  return m.group(1)!;
}

void main() {
  final version = _read('../VERSION').trim();

  test('VERSION is a bare semantic version', () {
    expect(
      version,
      matches(RegExp(r'^\d+\.\d+\.\d+$')),
      reason: 'VERSION contains "$version"',
    );
  });

  test('every version mirror matches VERSION', () {
    final pubspecVersion = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true);
    final tomlVersion = RegExp(r'^version\s*=\s*"([^"]+)"', multiLine: true);
    final gradleVersion = RegExp(
      r'^pluginVersion\s*=\s*(\S+)\s*$',
      multiLine: true,
    );
    final lspVersion = RegExp(r"'serverInfo':\s*\{[^}]*'version':\s*'([^']+)'");

    final mirrors = <String, String>{
      '../doxa/pubspec.yaml': _firstMatch(
        _read('../doxa/pubspec.yaml'),
        pubspecVersion,
        '../doxa/pubspec.yaml',
      ),
      '../doxa_tooling/pubspec.yaml': _firstMatch(
        _read('../doxa_tooling/pubspec.yaml'),
        pubspecVersion,
        '../doxa_tooling/pubspec.yaml',
      ),
      '../doxa_stdlib/pubspec.yaml': _firstMatch(
        _read('../doxa_stdlib/pubspec.yaml'),
        pubspecVersion,
        '../doxa_stdlib/pubspec.yaml',
      ),
      '../editors/vscode/package.json':
          (jsonDecode(_read('../editors/vscode/package.json'))
                  as Map<String, dynamic>)['version']
              as String,
      '../editors/jetbrains/gradle.properties': _firstMatch(
        _read('../editors/jetbrains/gradle.properties'),
        gradleVersion,
        '../editors/jetbrains/gradle.properties',
      ),
      '../doxa_tooling/lib/src/lsp/handler.dart': _firstMatch(
        _read('../doxa_tooling/lib/src/lsp/handler.dart'),
        lspVersion,
        '../doxa_tooling/lib/src/lsp/handler.dart',
      ),
      '../editors/zed/extension.toml': _firstMatch(
        _read('../editors/zed/extension.toml'),
        tomlVersion,
        '../editors/zed/extension.toml',
      ),
      '../editors/zed/Cargo.toml': _firstMatch(
        _read('../editors/zed/Cargo.toml'),
        tomlVersion,
        '../editors/zed/Cargo.toml',
      ),
    };

    for (final entry in mirrors.entries) {
      expect(
        entry.value,
        version,
        reason: '${entry.key} disagrees with VERSION',
      );
    }
  });

  test(
    'doxa_tooling depends on the matching kernel without a path override',
    () {
      final pubspec = _read('../doxa_tooling/pubspec.yaml');
      final dependency = RegExp(
        r'^\s*doxa:\s*(\^[0-9]+\.[0-9]+\.[0-9]+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(dependency, isNotNull, reason: 'missing doxa dependency');
      expect(dependency!.group(1), '^$version');
      expect(
        pubspec,
        isNot(contains('dependency_overrides:')),
        reason: 'the published pubspec must not carry a local override',
      );
    },
  );

  test('package-local changelogs mention the release', () {
    expect(_read('../doxa/CHANGELOG.md'), contains('## $version'));
    expect(_read('../doxa_tooling/CHANGELOG.md'), contains('## $version'));
    expect(_read('../doxa_stdlib/CHANGELOG.md'), contains('## $version'));
  });
}
