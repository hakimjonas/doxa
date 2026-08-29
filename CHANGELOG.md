# Changelog

## Unreleased

- Added a `doxa/proofState` server notification. After every document check
  the language server reports one entry per `by { ... }` block: the span,
  whether the block proved its goal, and the open goals with their binder
  context and expected type. Positions are UTF-16.
- Added kernel support for proof-state snapshots: `elabDecl` accepts a
  `proofStateSink`, and each `by` block records an immutable
  `ProofStateBlock` (new export `package:doxa/doxa.dart`) as its
  elaboration finishes, on success and on failure.
- The VS Code extension shows the open goals for the block under the cursor
  in a webview panel (`Doxa: Show Proof State`).
- Declared the JetBrains support policy: the plugin is developed and tested
  against IntelliJ IDEA Community Edition and other IDEs built on IntelliJ
  Platform 2025.1; commercial IDEs work as-is but are untested.
- The release workflow builds native binaries on five runners (linux-x64,
  linux-arm64, macos-arm64, macos-x64, windows-x64) and attaches them, with a
  `checksums.txt` file, to the GitHub release.

## 0.8.2

- Fixed duplicate-declaration diagnostics when an imported path is resolved
  more than once.
- Reported the release version from the language server.
- Moved the VS Code and JetBrains extensions into `editors/` in this
  repository.
- Added a configurable language-server path and scoped file watching to the VS
  Code extension.

## 0.8.0

- Published the first preview release of the kernel, command-line tooling,
  standard library, VS Code extension, and JetBrains plugin.
- Added checked standard-library proofs and the `sqrt2` natural-number descent
  case study.
