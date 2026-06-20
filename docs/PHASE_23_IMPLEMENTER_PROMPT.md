# Phase 23 Implementer Prompt

> Copy this message as a prompt to a fresh implementer session.
> After implementation, we audit together.

---

Implement Phase 23 (Namespace-Qualified Modules) for the Doxa proof
checker. Follow the plan in `docs/PHASE_23_IMPLEMENTATION_PLAN.md`.
Read that document first — it contains the design rationale and full
step-level detail. This prompt is the execution specification; the
plan document has rationale and alternatives.

## Context

Doxa is a Dart monorepo with two packages:
- `doxa/` — kernel library (elaborator, parser, evaluator, type checker)
- `doxa_tooling/` — CLI, WASM, LSP, REPL, tests

The current module system (Phase 18) uses a flat namespace: every
imported name is visible unqualified. Dots in names like `Nat.rec` are
just a naming convention — stored as flat string keys. Phase 23 makes
dots meaningful: `Nat.plus` resolves namespace `Nat` → unqualified name
`plus`.

**Active branch:** `doxa-extended`

## Requirement

After Phase 23:
1. `import "nat.doxa"` → names available unqualified AND qualified as
   `Nat.<name>` (e.g., `Nat.zero`, `Nat.plus`)
2. `import "nat.doxa" as N` → names available unqualified AND qualified
   as `N.<name>` (alias replaces auto-derived prefix)
3. Duplicate unqualified names error (unchanged); qualified names never
   collide
4. All 885 existing tests continue to pass
5. New tests for qualified access, `as` alias, and cross-module
   disambiguation

## Design (critical — follow exactly)

**No kernel changes.** Zero changes to `term.dart`, `eval.dart`,
`conv.dart`, `check.dart`, `value.dart`, or `env.dart`. Everything works
at the elaboration level.

**Namespace map is `Map<String, Set<String>>`** — prefix → set of
unqualified names available under that prefix. It lives in `TopEnv` and
gets accumulated in `checkSource`. Cheap to build, no duplication of
`TopBindingEntry`.

**Resolution for `DotQual.ifIer.name`:**
1. Record projection (existing, first priority)
2. **NEW**: namespace-qualified lookup — if qualifier is `SIdent(prefix)`
   and `namespaceBindings[prefix]` contains `name`, resolve via flat
   `topBindings[name]`
3. Flatten-to-dotted-string then flat lookup (existing fallback, backward
   compat for `Nat.rec`-style keys)

**Kernel term.** Namespace-resolved references produce `TTop(name)` with
the bare unqualified name (not the dotted string). At eval time,
`topBindings[name]` provides the entry.

## Files to Change (in order)

### 1. `doxa/lib/src/surface.dart`
- `SImportKind`: add `final String? alias` field
- Update `==`, `hashCode`, `toString`, and the constructor
- Constructor signature: `const SImportKind(this.path, {this.importedNames = const [], this.alias})`

### 2. `doxa/lib/src/parse.dart`
- Extend `_importDecl` to parse optional `as <Identifier>` after the
  brace block. The `as` keyword + identifier must come after both
  the path string and any brace block.
- All four forms must work:
  ```
  import "p"                  → alias: null, importedNames: []
  import "p" { a }            → alias: null, importedNames: [a]
  import "p" as N             → alias: "N", importedNames: []
  import "p" { a } as N       → alias: "N", importedNames: [a]
  ```
- Don't let `as` be parsed as part of a brace block's ident.

### 3. `doxa/lib/src/elab.dart` — `TopEnv` class
- Add field: `final Map<String, Set<String>> namespaceBindings`
- Constructor: add `this.namespaceBindings = const {}` as optional
  parameter (positional after `classRegistry`)
- `TopEnv.empty`: add `namespaceBindings: const {}`
- Add method:
  ```dart
  bool hasQualified(String prefix, String name) =>
      namespaceBindings[prefix]?.contains(name) ?? false;
  ```

### 4. `doxa/lib/src/elab.dart` — `_modulePrefix` helper
- New function:
  ```dart
  String _modulePrefix(String path) {
    final filename = path.split(RegExp(r'[/\\]')).last;
    final stem = filename.endsWith('.doxa')
        ? filename.substring(0, filename.length - '.doxa'.length)
        : filename;
    if (stem.isEmpty) return stem;
    return stem[0].toUpperCase() + stem.substring(1);
  }
  ```

### 5. `doxa/lib/src/elab.dart` — `_inferExpr` SDotKind case
- Insert namespace-qualified lookup between record projection and
  flatten-to-string fallback:
  ```dart
  // After record projection try/catch, before final flat = ...
  if (qualifier.kind is SIdentKind) {
    final qualName = (qualifier.kind as SIdentKind).name;
    if (state.topEnv.hasQualified(qualName, name)) {
      final topEntry = state.ctx.env.lookupTop(name);
      if (topEntry != null) {
        _recordSemInfo(
          state, expr.span, '$qualName.$name',
          SemInfoKind.topBinding, topEntry.type,
          state.topEnv.spanOf(name),
        );
        return (TTop(name), topEntry.type);
      }
    }
  }
  ```

### 6. `doxa/lib/src/elab.dart` — `DeclResult` record types
- Every function returning the anonymous record type needs a new field:
  `Map<String, Set<String>> namespaceBindings`
- Functions to update (search for return records with `bindings:`,
  `dataDecls:`, etc.):
  - `_elabDecl` (all the `case` arms: SValKind, SDataKind, SFunKind,
    SImportKind, SFunBlockKind, STypeclassKind, SInstanceKind,
    SQuotKind, SOpenKind, STacticKind)
  - `checkDeclResult`
  - `_elabFunBlock` / `_elaborateFunBlock` (if separate)
  - `_elabTypeclassDecl` (if separate)
  - `_elabQuot` (if separate)
- Default value: `const <String, Set<String>>{}` for non-import arms
- For `_processImport`: compute and return the namespace map (see Step 7)
- For `_elabDecl`'s `SDataKind` arm: add the data name as a namespace
  prefix, with recursor names in the set (see Step 8)

### 7. `doxa/lib/src/elab.dart` — `_processImport`
- Accept new parameter: `String? alias`
- After selective-import filtering and before duplicate detection,
  compute module prefix and build namespace map:
  ```dart
  final modPrefix = alias ?? _modulePrefix(path);
  final nsMap = <String, Set<String>>{};
  nsMap[modPrefix] = {
    for (final b in localBindings) b.name,
    for (final d in localDataDecls) d.name,
  };
  ```
- Return `nsMap` as `namespaceBindings` in the record
- `_elabDecl` SImportKind arm: pass `alias` through

### 8. `doxa/lib/src/elab.dart` — `_elabDecl` SDataKind: recursor namespace
- After `unsugarDataRecursors` produces bindings, add the data name
  as a namespace prefix containing the recursor names:
  ```dart
  // In the SDataKind arm, after produced bindings are computed:
  final nsMap = <String, Set<String>>{
    dataName: {for (final b in produced.bindings) b.name},
  };
  ```
- Pass `nsMap` as `namespaceBindings` in the returned record
- This makes `Nat.rec` resolvable via namespace-qualified lookup
  (in addition to the existing flat-key fallback)

### 9. `doxa_tooling/bin/doxa.dart` — `checkSource` pipeline
- Add accumulator: `var namespaceBindings = <String, Set<String>>{};`
- Pass to `TopEnv(...)` construction at line 253:
  ```dart
  final env = TopEnv(bindings, dataDecls, const {}, namespaceBindings);
  ```
- After each declaration processing (after `bindings = [...]`), merge:
  ```dart
  namespaceBindings = _mergeNamespaceSets(
    namespaceBindings,
    produced.namespaceBindings,
  );
  ```
- Helper:
  ```dart
  Map<String, Set<String>> _mergeNamespaceSets(
    Map<String, Set<String>> a,
    Map<String, Set<String>> b,
  ) {
    if (b.isEmpty) return a;
    final result = Map<String, Set<String>>.from(a);
    for (final entry in b.entries) {
      result[entry.key] = {
        ...?result[entry.key],
        ...entry.value,
      };
    }
    return result;
  }
  ```

### 10. `doxa/lib/src/elab.dart` — all `TopEnv(...)` construction sites
- Search for `TopEnv(` in elab.dart
- Every construction must pass the 4th positional argument
  `namespaceBindings`. Use `const {}` where no namespace map is
  needed (e.g., in `toCtx()`, `checkDeclResult` internal calls).
- Worst case: the iterated construction in `_processImport` line 3291
  needs to thread the caller's `namespaceBindings` through.

### 11. Tests — `doxa_tooling/test/namespace_test.dart`
- New file following the pattern of `import_test.dart` (use
  `runSource`/`runFile` helpers)
- Tests:
  1. `Nat.zero` works (qualified access)
  2. `Nat.plus zero zero` works (qualified name in application)
  3. `Nat.Nat` in type annotation works
  4. Unqualified `zero` still works (backward compat)
  5. `import "nat.doxa" as M` → `M.zero` works (alias)
  6. `Nat.rec` works (recursor via namespace lookup)
  7. Duplicate unqualified name from two modules errors
  8. `Nat.plus` and a hypothetical `Int.plus` in separate namespaces
     — qualified access works (no error on unqualified conflict of plus)
  9. Selective import: `import "nat.doxa" { zero }` — `Nat.zero` works
     but `Nat.plus` does not
  10. Selective import with alias: `import "nat.doxa" { plus } as N` —
      `N.plus` works, bare `zero` not available

## Compat Tests — Must Still Pass
- `doxa/test/dotted_name_test.dart` — all tests
- `doxa_tooling/test/import_test.dart` — all tests
- `doxa_tooling:test -r expanded` — all 885 tests

## Verification (run after implementation)
```bash
dart analyze doxa/
dart analyze doxa_tooling/
dart run doxa_tooling:test -r expanded
dart format --set-exit-if-changed doxa/ doxa_tooling/
dart run doxa_tooling:bin/doxa check example/proofs.doxa
dart run doxa_tooling:bin/doxa check lib/stdlib/proofs.doxa
```

## Edge Cases to Handle

1. **`_processImport` built within `_processImport`**: When importing
   nat.doxa which itself imports bool.doxa, the inner import's
   `namespaceBindings` should merge into the outer. The current design
   returns `namespaceBindings` per import and the pipeline merges them.

2. **`_processImport` iterated construction**: Line 3291 builds a
   running `TopEnv` for each declaration in the imported file. This
   running env must carry the namespace map so that declarations inside
   the imported file can use qualified names from transitive imports.

3. **Selective import**: If `importedNames` filters to only `["plus"]`,
   only `plus` (not `zero`) appears in the namespace set for that module.
   The `localBindings` are already filtered by `_processImport` — the
   namespace set is built from the filtered `localBindings`, so it
   automatically respects selective imports.

4. **`TTop` with dotted names in existing tests**: Some tests assert
   `TTop("Nat.rec")` with the dotted string. After the change,
   namespace-qualified resolution produces `TTop("rec")`. However,
   the existing flatten-to-string fallback still produces
   `TTop("Nat.rec")`. Tests that exercise the older path should still
   pass.

5. **`_flattenDottedIdent` still needed**: The flatten-to-string
   function remains for backward compatibility (old-style dotted keys
   in `topBindings`) and for semantically-ambiguous dotted names.
   Do not remove it.

6. **Recursor name `Nat.rec`**: Both the namespace map and the flat
   `topBindings` should have entries for the recursor. The namespace
   map enables `Nat.rec` resolution. The flat map ensures backward
   compat with any existing terms carrying `TTop("Nat.rec")`.

## Sanity Check During Audit

When we audit, verify:
- [ ] `dart analyze` 0 issues in both packages
- [ ] `dart format` clean
- [ ] All 885 existing tests pass
- [ ] New namespace tests pass
- [ ] `example/proofs.doxa` type-checks (uses `import` + dotted names)
- [ ] `lib/stdlib/proofs.doxa` type-checks
- [ ] No change to `term.dart`, `eval.dart`, `conv.dart`, `env.dart`
- [ ] `TTop` has no new fields (verifies zero kernel changes)
- [ ] `SImportKind` has `alias` field
- [ ] Parser handles all four `import` forms
- [ ] `TopEnv` has `namespaceBindings` and `hasQualified`
- [ ] `_inferExpr` SDotKind has namespace lookup path
- [ ] `_processImport` returns `namespaceBindings`
- [ ] `checkSource` accumulates `namespaceBindings`
