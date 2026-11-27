# Doxa extension for Zed

Language support for [Doxa](https://github.com/hakimjonas/doxa), a
dependently typed proof checker.

## What it provides

- Syntax highlighting, bracket matching, auto-indentation, and code
  outline through the
  [tree-sitter-doxa](https://github.com/hakimjonas/tree-sitter-doxa)
  grammar (generated from the declarative grammar IR in the Doxa
  repository).
- Diagnostics, hover, go-to-definition, completion, references, rename,
  document symbols, signature help, formatting, folding ranges, and
  semantic tokens through the Doxa language server (`doxa lsp`).

## Installing the language server

Zed resolves extension language-server commands relative to the extension
work directory. The extension looks for `doxa` on the worktree's `PATH` and
does not read outside its own extension directory, so the directory
containing `doxa` must be on `PATH`.

Install `doxa` with one of:

- A native binary from the
  [doxa releases](https://github.com/hakimjonas/doxa/releases)
  (linux-x64, linux-arm64, macos-arm64, macos-x64, windows-x64), placed in
  `~/.local/bin` or another directory on `PATH`.
- `dart pub global activate doxa_tooling` (requires the Dart SDK). The
  executable is in `~/.pub-cache/bin`, which must be on `PATH`.
- Build from source: `dart compile exe bin/doxa.dart` in `doxa_tooling`,
  then put the binary's directory on `PATH`.

If `doxa` is not on `PATH`, the extension reports an error naming these
options.

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

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
