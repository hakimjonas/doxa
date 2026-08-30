# Doxa

Doxa is a dependently typed proof checker written in Dart. Its kernel checks a
surface language with dependent functions, inductive types, pattern matching,
implicit arguments, propositional equality, and a hierarchy of universes.

This extension adds Doxa language support to VS Code.

## Features

- Syntax highlighting for `.doxa` files
- Live diagnostics with source spans while you edit
- Hover documentation for top-level names and local binders
- Go-to-definition and find references
- Completion for in-scope names
- Rename, with prepare-rename support
- Document formatting in canonical style
- Document symbols for the outline panel
- Semantic highlighting driven by the server's type information
- The Doxa: Show Proof State panel, which lists the goals still open in
  the `by { ... }` block under the cursor

## Installing the language server

The extension drives the `doxa` command line tool. Install it one of
these ways:

- Download a binary for your platform from the
  [doxa releases](https://github.com/hakimjonas/doxa/releases)
  (linux-x64, linux-arm64, macos-arm64, macos-x64, windows-x64), or
- Run `dart pub global activate doxa_tooling` (requires Dart 3.7 or
  later), or
- Build from source with `dart compile exe bin/doxa.dart` in the
  `doxa_tooling` directory of the
  [doxa repository](https://github.com/hakimjonas/doxa).

The extension starts `doxa` from the editor's PATH. If the binary is
installed somewhere the editor cannot see, point the extension at it in
settings:

```json
{ "doxa.server.path": "/path/to/doxa" }
```

## Proof state

Open a file containing a `by { ... }` block, place the cursor inside the
block, and run `Doxa: Show Proof State` from the command palette. The
panel lists the goals that are still open in that block, with the
binders in scope and the expected type of each goal.
