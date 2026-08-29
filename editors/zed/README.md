# Doxa extension for Zed

Language support for [Doxa](https://github.com/hakimjonas/doxa), a
dependently typed proof checker.

## What it provides

- Syntax highlighting, bracket matching, auto-indentation, and code
  outline through the
  [tree-sitter-doxa](https://github.com/hakimjonas/tree-sitter-doxa)
  grammar (generated from the declarative grammar IR in the Doxa
  repository).
- Diagnostics, hover, go-to-definition, completion, references, and
  formatting through the Doxa language server (`doxa lsp`).

## Installing the language server

The extension starts the `doxa` binary from your PATH. Install one:

- Download a native binary from the
  [doxa releases](https://github.com/hakimjonas/doxa/releases)
  (linux-x64, linux-arm64, macos-arm64, macos-x64, windows-x64), or
- Run `dart pub global activate doxa_tooling` (requires the Dart SDK),
  or
- Build from source: `dart compile exe bin/doxa.dart` in the
  `doxa_tooling` directory of the Doxa repository.

## Semantic highlighting

The server implements `semanticTokens/full`. Zed requests semantic
tokens only when enabled; add this to your Zed settings:

```json
{
  "languages": {
    "Doxa": {
      "semantic_tokens": "combined"
    }
  }
}
```

## Development

The tree-sitter grammar is pinned by `rev` in `extension.toml`. To
update it, regenerate the grammar (`tool/grammar/generate.sh` in the
Doxa repository), push tree-sitter-doxa, and update the `rev`.
