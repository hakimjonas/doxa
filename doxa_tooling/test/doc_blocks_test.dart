/// Checks the `doxa` code fences in the normative documents.
///
/// Each unmarked fence is written to a temporary Dart project and checked as
/// a complete file, so blocks that use `package:` imports resolve.
///
/// A fence whose preceding non-blank line is `<!-- doxa: fragment -->` is
/// skipped. Fragments use metavariables, need an expected type, or need
/// surrounding context, so they cannot be checked standalone. The marker is
/// documented in `AGENTS.md`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doxa/src/source.dart';
import 'package:test/test.dart';

import '../bin/doxa.dart' show checkSource;

/// Documents whose `doxa` fences are checked. Extend this list when another
/// document starts carrying checked examples.
const _documents = ['../SPEC.md', '../README.md'];

/// Marks a fence as a fragment that cannot be checked standalone.
const _fragmentMarker = '<!-- doxa: fragment -->';

void main() {
  final stdlibRoot = Directory('../doxa_stdlib').absolute.path;
  late Directory project;
  late List<_Block> blocks;

  setUpAll(() async {
    project = Directory.systemTemp.createTempSync('doxa-doc-blocks-');
    File('${project.path}/pubspec.yaml').writeAsStringSync('''
name: doxa_doc_blocks
environment:
  sdk: ^3.7.0
dev_dependencies:
  doxa_stdlib:
    path: $stdlibRoot
''');
    final pub = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: project.path);
    expect(pub.exitCode, 0, reason: '${pub.stdout}\n${pub.stderr}');

    blocks = [for (final path in _documents) ..._extract(File(path))];
  });

  tearDownAll(() {
    if (project.existsSync()) {
      project.deleteSync(recursive: true);
    }
  });

  test('the normative documents contain doxa blocks', () {
    expect(blocks, isNotEmpty);
  });

  test('doxa blocks in the normative documents check', () {
    final failures = <String>[];
    var checked = 0;
    var skipped = 0;

    for (final block in blocks) {
      if (block.fragment) {
        skipped++;
        continue;
      }
      final file = File('${project.path}/block_${block.ordinal}.doxa')
        ..writeAsStringSync(block.source);
      final out = _BufferedSink();
      final err = _BufferedSink();
      final code = checkSource(
        SourceFile(filename: file.path, text: block.source),
        out: out,
        err: err,
      );
      checked++;
      if (code != 0) {
        failures.add(
          '${block.path}:${block.line} (${block.firstLine})\n'
          '${err.toString().trimRight()}',
        );
      }
    }

    print('doc blocks: $checked checked, $skipped fragments skipped');
    expect(
      failures,
      isEmpty,
      reason: 'fenced doxa blocks failed to check:\n\n${failures.join('\n\n')}',
    );
  });
}

/// A fenced `doxa` block and the place it was found.
final class _Block {
  _Block({
    required this.path,
    required this.line,
    required this.source,
    required this.fragment,
    required this.ordinal,
  });

  /// File the block was extracted from.
  final String path;

  /// 1-based line number of the opening fence.
  final int line;

  /// Contents between the fences.
  final String source;

  /// Whether the marker skipped this block.
  final bool fragment;

  /// Position in the combined block list, used for unique temporary names.
  final int ordinal;

  /// The first content line, for failure messages.
  String get firstLine => source.split('\n').first.trim();
}

List<_Block> _extract(File file) {
  final lines = file.readAsLinesSync();
  final blocks = <_Block>[];
  final buffer = <String>[];
  var inFence = false;
  var collect = false;
  var fragment = false;
  var fenceLine = 0;
  var lastNonBlank = '';

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    final isFence = trimmed.startsWith('```');

    if (!inFence) {
      if (isFence) {
        inFence = true;
        collect = _language(trimmed) == 'doxa';
        fragment = lastNonBlank == _fragmentMarker;
        fenceLine = i + 1;
        buffer.clear();
      } else if (trimmed.isNotEmpty) {
        lastNonBlank = trimmed;
      }
      continue;
    }

    if (isFence) {
      inFence = false;
      if (collect) {
        blocks.add(
          _Block(
            path: file.path,
            line: fenceLine,
            source: buffer.join('\n'),
            fragment: fragment,
            ordinal: blocks.length,
          ),
        );
      }
      lastNonBlank = '';
      continue;
    }

    if (collect) {
      buffer.add(line);
    }
  }

  return blocks;
}

String _language(String fence) {
  final info = fence.substring(3).trim();
  return info.split(RegExp(r'\s+')).first;
}

class _BufferedSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  void write(Object? obj) {
    _buffer.write(obj);
  }

  @override
  void writeln([Object? obj = '']) {
    _buffer.writeln(obj);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  @override
  String toString() => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
}
