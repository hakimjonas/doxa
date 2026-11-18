/// Resolution of Doxa `import` specifiers against the importing file.
///
/// A specifier is either a relative path, resolved against the directory of
/// the importing file, or a `package:` URI, resolved through the nearest
/// `.dart_tool/package_config.json` above that file. A package URI names the
/// package's library root, so `package:name/a/b.doxa` resolves to
/// `<rootUri>/lib/a/b.doxa`, or to the configured `packageUri` when the
/// package records one.
library;

import 'dart:convert';
import 'dart:io';

/// The URI scheme that marks a package import.
const String packageImportScheme = 'package:';

/// The default package library directory recorded by `dart pub get`.
const String _defaultPackageUri = 'lib/';

/// Whether [importPath] names a package URI.
bool isPackageImport(String importPath) =>
    importPath.startsWith(packageImportScheme);

/// A `package:` import that could not be resolved.
///
/// The resolver throws this instead of falling back to a relative path, so a
/// missing dependency is reported as a configuration error. [configPath] is
/// `null` when no package configuration exists above the importing file;
/// otherwise it names the configuration that was consulted.
final class PackageImportError implements Exception {
  /// The import specifier as written.
  final String importPath;

  /// The package name between `package:` and the first `/`.
  final String packageName;

  /// The file whose import could not be resolved.
  final String currentFile;

  /// The consulted package configuration, or `null` when none was found.
  final String? configPath;

  /// Whether the specifier is malformed (no package name or no path).
  final bool malformedSpecifier;

  /// Creates a package-import resolution error.
  const PackageImportError({
    required this.importPath,
    required this.packageName,
    required this.currentFile,
    required this.configPath,
    this.malformedSpecifier = false,
  });

  @override
  String toString() =>
      'PackageImportError($packageName from $currentFile: $importPath)';
}

/// Resolve [importPath] against [currentFile].
///
/// Relative specifiers resolve against the directory of [currentFile].
/// Package specifiers resolve through the nearest package configuration.
/// Throws [PackageImportError] when a package specifier cannot be resolved;
/// it never falls back to a relative path.
String resolveImportPath(String importPath, String currentFile) {
  if (!isPackageImport(importPath)) {
    return Uri.file(currentFile).resolve(importPath).toFilePath();
  }
  return _resolvePackageImport(importPath, currentFile);
}

String _resolvePackageImport(String importPath, String currentFile) {
  final specifier = importPath.substring(packageImportScheme.length);
  final slash = specifier.indexOf('/');
  if (slash <= 0 || slash == specifier.length - 1) {
    throw PackageImportError(
      importPath: importPath,
      packageName: slash <= 0 ? specifier : specifier.substring(0, slash),
      currentFile: currentFile,
      configPath: null,
      malformedSpecifier: true,
    );
  }
  final packageName = specifier.substring(0, slash);
  final relativePath = specifier.substring(slash + 1);

  final configPath = _findPackageConfig(currentFile);
  if (configPath == null) {
    throw PackageImportError(
      importPath: importPath,
      packageName: packageName,
      currentFile: currentFile,
      configPath: null,
    );
  }

  final libraryRoot = _libraryRoot(configPath, packageName);
  if (libraryRoot == null) {
    throw PackageImportError(
      importPath: importPath,
      packageName: packageName,
      currentFile: currentFile,
      configPath: configPath,
    );
  }

  return libraryRoot.resolve(relativePath).toFilePath();
}

/// Walk up from [currentFile] to the filesystem root, returning the first
/// `.dart_tool/package_config.json` found.
String? _findPackageConfig(String currentFile) {
  var directory = File(currentFile).absolute.parent;
  while (true) {
    final candidate = File('${directory.path}/.dart_tool/package_config.json');
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
}

/// Read the library root of [packageName] from [configPath].
///
/// `rootUri` is relative to the configuration file's directory, following the
/// Dart package-configuration format. Returns `null` when the configuration
/// cannot be read or does not declare the package.
Uri? _libraryRoot(String configPath, String packageName) {
  final configFile = File(configPath);
  final Object? decoded;
  try {
    decoded = jsonDecode(configFile.readAsStringSync());
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return null;

  for (final entry in packages) {
    if (entry is! Map<String, Object?>) continue;
    if (entry['name'] != packageName) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) return null;
    final packageUri = entry['packageUri'];
    final libraryUri =
        packageUri is String && packageUri.isNotEmpty
            ? packageUri
            : _defaultPackageUri;
    final libraryPath = libraryUri.endsWith('/') ? libraryUri : '$libraryUri/';
    final configDirectory = Uri.file('${configFile.parent.path}/');
    final root = configDirectory.resolve(rootUri);
    // A package root is a directory. Pub writes an absolute `rootUri`
    // without a trailing slash, and URI resolution treats the last segment
    // of a slash-less URI as a file name, so make the directory explicit.
    final rootDirectory =
        root.path.endsWith('/') ? root : root.replace(path: '${root.path}/');
    return rootDirectory.resolve(libraryPath);
  }
  return null;
}
