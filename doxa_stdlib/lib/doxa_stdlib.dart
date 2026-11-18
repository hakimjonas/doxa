/// Locates the packaged Doxa standard library.
///
/// The library is plain `.doxa` source under [stdlibRelativePath]. A
/// consumer needs the directory, not a Dart API: the Doxa checker reads
/// the files and resolves their `import` declarations.
///
/// ```dart
/// import 'package:doxa_stdlib/doxa_stdlib.dart';
///
/// void main() {
///   print(stdlibRootPath); // …/doxa_stdlib/lib/stdlib
/// }
/// ```
///
/// [stdlibRoot] resolves through the ambient package configuration, so it
/// works from a package test, a CLI, or any project that depends on
/// `doxa_stdlib`. It has no dependency on the Doxa kernel or tooling.
library;

import 'dart:isolate';

/// The directory of the standard library, relative to the package root.
const String stdlibRelativePath = 'lib/stdlib';

/// The package URI of this library, used to resolve the package root.
final Uri _selfUri = Uri.parse('package:doxa_stdlib/doxa_stdlib.dart');

/// The packaged standard-library directory as an absolute [Uri].
///
/// Throws a [StateError] when no package configuration is available, for
/// example when the library is loaded outside a Dart package context.
Uri get stdlibRoot {
  final resolved = Isolate.resolvePackageUriSync(_selfUri);
  if (resolved == null) {
    throw StateError(
      'cannot resolve $_selfUri: the Dart package configuration does not '
      'list doxa_stdlib. Run `dart pub get` in the depending project.',
    );
  }
  return resolved.resolve('stdlib');
}

/// The packaged standard-library directory as a filesystem path.
///
/// Convenience form of [stdlibRoot] for callers that pass paths to
/// processes or `dart:io` APIs.
String get stdlibRootPath => stdlibRoot.toFilePath();
