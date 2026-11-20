# doxa_tooling

`doxa_tooling` provides the `doxa` command-line executable for checking and
formatting Doxa files, an interactive REPL, and an LSP server. It depends on
the `doxa` kernel package.

Status: experimental; there is no current release. doxa 0.8.4 was published to
pub.dev and retracted the same day, and doxa_tooling and doxa_stdlib have never
been published. Publishing is on hold. The repository status is at
https://github.com/hakimjonas/doxa#status.

The package requires Dart 3.7 or later and is licensed under GPL-3.0-or-later.
Repository documentation, examples, and editor integrations are available at
<https://github.com/hakimjonas/doxa>.

From a source checkout:

```sh
dart run bin/doxa.dart check ../example/proofs.doxa
```

Local development uses a path override. Create `doxa_tooling/pubspec_overrides.yaml`:

```yaml
dependency_overrides:
  doxa:
    path: ../doxa
```

The file is gitignored. CI and the release binary build generate it before
`dart pub get`. The published pubspec depends on the matching `doxa` version
and carries no override.
