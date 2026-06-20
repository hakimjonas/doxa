# Phase 24.5 — Tooling Sync

## Goal

Bring the three profiling/benchmarking tools up to date with Phases 23 and
24. Each tool has its own inline prelude string (missing `Acc`) and uses
`TopEnv(bindings, dataDecls)` with only 2 positional args (missing
`classRegistry` and `namespaceBindings`). Fix all three.

## Why Now

Before Phase 25 (stdlib expansion), the tools must be accurate. Phase 25
will add `Int`, `Rat`, `Acc`-based proofs, and qualified-name references to
the stdlib. The tools process stdlib files; if their preludes are stale or
their `TopEnv` doesn't carry namespaces, they'll silently produce wrong
results or crash.

## Scope

Three files, ~15 lines changed each.

### File 1: `tool/benchmark.dart`

1. Add `Acc` to `_preludeSource` (line 35-38)
2. Update `_loadPrelude()` return type and record to include
   `Map<String, Set<String>> namespaceBindings`
3. Add `var namespaceBindings = <String, Set<String>>{}` accumulator
4. Pass `classRegistry` (3rd) + `namespaceBindings` (4th) to all
   `TopEnv(...)` calls (lines 58, 60)
5. Merge `produced.namespaceBindings` after each decl
6. Add `_mergeNamespace` helper (or import from elab.dart if exposed)

### File 2: `tool/profile.dart`

1. Add `Acc` to `prelude` string (line 13-17)
2. Add `var namespaceBindings = <String, Set<String>>{}` accumulator
3. Pass 3rd + 4th args to all `TopEnv(...)` calls (lines 24, 26, 49, 54, 86, 91, 112, 114)
4. Merge `produced.namespaceBindings` after each decl
5. Add `_mergeNamespace` helper

### File 3: `tool/alloc_profile.dart`

1. Add `Acc` to `_prelude` string (line 16-20)
2. Add `var namespaceBindings = <String, Set<String>>{}` accumulator
3. Pass 3rd + 4th args to all `TopEnv(...)` calls (lines 26, 28, 59, 64, 100, 105, 183, 185)
4. Merge `produced.namespaceBindings` after each decl
5. Add `_mergeNamespace` helper

### `_mergeNamespace` helper (replicated in each tool)

```dart
Map<String, Set<String>> _mergeNamespace(
  Map<String, Set<String>> a,
  Map<String, Set<String>> b,
) {
  if (b.isEmpty) return a;
  final result = Map<String, Set<String>>.from(a);
  for (final entry in b.entries) {
    result[entry.key] = {...?result[entry.key], ...entry.value};
  }
  return result;
}
```

## Verification

```bash
dart analyze doxa/
dart run tool/benchmark.dart --repeat=1 --warmup=0 2>&1 | tail -5
dart run tool/profile.dart 2>&1 | tail -3
dart run tool/alloc_profile.dart 2>&1 | tail -3
```

All three tools must run without error and produce their normal output.
