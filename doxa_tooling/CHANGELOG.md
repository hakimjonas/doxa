# Changelog

## 0.8.4

- Added tooling tests for `Nat` division, modulo, prime, coprime, gcd, and
  lcm edge cases.
- Reject `typeclass`, `impl`, `termination_by`, and quotient `mk` / `lift`
  surfaces with dedicated diagnostics.
- Added a version-sync test across `VERSION` and the package and editor
  mirrors.
- Updated the tutorial and proof-guide status for the rejected surfaces and
  the completed sqrt2 proof.
- Depends on `doxa ^0.8.4`. The local path override moved to the gitignored
  `pubspec_overrides.yaml`; the published pubspec has no override.

## 0.8.2

- Fixed duplicate-declaration diagnostics when an imported path is resolved
  more than once.
- Reported the release version from the language server.

## 0.8.0

- Published the first preview of the Doxa command-line tools, REPL, formatter,
  and language server.
