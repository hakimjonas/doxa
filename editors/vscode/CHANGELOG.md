# Changelog

## Unreleased

- Added the Doxa Proof State panel: open goals for the `by { ... }` block
  under the cursor, updated from the server's `doxa/proofState`
  notification without a round-trip on cursor movement
- Registered the `Doxa: Show Proof State` command

## 0.8.2

- User-configurable language server path (`doxa.server.path` setting)
- Scoped file watcher to workspace folders
- ESBuild bundling for reproducible packaging
- Fixed unused imports, added `repository` and `keywords` to manifest

## 0.8.0 — 2025-08-09

- Initial preview release
- Syntax highlighting via TextMate grammar
- LSP integration: diagnostics, hover, go-to-definition, completion, references, rename
- Semantic tokens for rich highlighting
- Document formatting, signature help, document symbols
