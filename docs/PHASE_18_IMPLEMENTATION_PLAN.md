# Phase 18 — Modules + Imports

## Part A: Design Note (prior-work study)

### Reference models

**Lean 4:** Imports are a build-system concern. `import ModuleName` statements in the
module header are resolved by the build system (Lake), which processes files in topological
order. Each module has a namespace derived from its file path. The kernel `Environment`
is append-only — imported constants are visible in the same flat namespace.
Source: `Lean/Environment.lean` (the `imports`/`modules` fields on `EnvironmentHeader`).

**Coq:** `Require Import Module` loads compiled `.vo` files. Modules become namespaces:
`Module.ident` is qualified access. Complex — namespaces can be opened/unsealed.

**Agda:** `open import Module` — imports and immediately opens the module's namespace.
Modules are explicit (`module Name where ...`), exports can be controlled.

### Decision: Inline import declarations with flat merge (simplest viable)

**Rationale:**

1. **No build system required.** Doxa is a single-binary checker, not a compiler with a
   build system. Inline `import "path"` declarations are processed during elaboration —
   load the file, elaborate and check it, merge its `TopEnv` into the current one.
   No separate compilation, no `.olean` files, no caching (yet).

2. **Flat namespace.** All imported names become available unqualified in the current
   scope. This matches Doxa's existing flat `Map<String, TopBindingEntry>` design.
   Qualified access (`Module.ident`) can be added later as sugar.

3. **Duplicate detection.** If an imported name conflicts with an existing name, the
   checker reports a `DuplicateDeclaration` error. Identical declarations (same name,
   same type, same term) are silently accepted (idempotent import).

4. **Prelude remains auto-imported.** For backward compatibility, the prelude is still
   loaded before user code. User code can optionally `import` additional stdlib modules.

5. **Stdlib reorganisation.** The monolithic stdlib files are split into per-concept
   modules (`nat.doxa`, `list.doxa`, `vec.doxa`, `proofs.doxa`). Each module `import`s
   its dependencies. The `proofs.doxa` that the test suite checks becomes a single file
   that imports shared modules instead of redeclaring everything.

### Key constraints

- **Cyclic imports:** Detected and rejected. The import graph must be a DAG. A set of
  already-imported paths is tracked during elaboration to detect cycles.
- **Path resolution:** Import paths are relative to the importing file's directory.
  Absolute paths or `lib/stdlib/` prefix resolution is added later.
- **No separate namespace:** All names are flat. `Module.ident` is not supported yet.
  This is the simplest model; namespaces can be added in a follow-up if needed.

---

## Part B: Implementation Plan (~200 lines, 6-10 sessions)

### Step 0 — Surface syntax + parser (~30 lines)

#### 0a. `SImportKind` (surface.dart)

Add to the `SDeclKind` hierarchy:

```dart
/// An import declaration: `import "path/to/file.doxa"`.
final class SImportKind extends SDeclKind {
  /// The module path (as parsed from the source).
  final String path;

  @override
  String get name => path;

  const SImportKind(this.path);

  @override
  bool operator ==(Object other) =>
      other is SImportKind && other.path == path;

  @override
  int get hashCode => Object.hash('SImportKind', path);
}
```

#### 0b. `_importDecl` parser (parse.dart)

```dart
/// An `import` declaration: `import "path/to/file.doxa"`.
final Parser<ParseError, SDecl> _importDecl = position<ParseError>().flatMap(
  (start) => _keyword('import')
      .skipThen(_strLit)  // quoted string literal
      .flatMap(
        (path) => position<ParseError>().map(
          (end) => SDecl(SImportKind(path), DoxaSpan(start, end)),
        ),
      ),
);
```

Add `_strLit` parser if one doesn't exist:
```dart
/// A double-quoted string literal.
final Parser<ParseError, String> _strLit = _sym('"')
    .skipThen(_notSym('"').many.map((cs) => cs.join()))
    .thenSkip(_sym('"'));
```

Add to `_decl`:
```dart
final Parser<ParseError, SDecl> _decl =
    _importDecl | _valDecl | _typeDecl | _funDecl | _dataDecl;
```

Add `"import"` to the reserved words list if keyword handling requires it.

---

### Step 1 — Elaborator import resolution (~50 lines)

#### 1a. `import` case in `_elabDecl` (elab.dart)

Add to the `_elabDecl` switch:

```dart
case SImportKind(:final path):
  return _processImport(topEnv, path, decl.span);
```

`_processImport`:

```dart
DeclResult _processImport(TopEnv topEnv, String path, DoxaSpan span) {
  // 1. Resolve path relative to current file's directory
  final resolvedPath = _resolveImportPath(path, _currentFilePath);

  // 2. Detect cycles
  if (_importStack.contains(resolvedPath)) {
    throw CyclicImport(resolvedPath, span);
  }

  // 3. Load and parse the file
  final source = File(resolvedPath).readAsStringSync();
  final prog = parseProgramOk(source);

  // 4. Push onto import stack, recurse
  _importStack.add(resolvedPath);
  var importedBindings = const <TopBinding>[];
  var importedDataDecls = const <DataDecl>[];
  var runningEnv = topEnv;
  for (final importDecl in prog.decls) {
    final produced = elabDecl(runningEnv, importDecl);
    final checked = checkDeclResult(runningEnv, produced);
    importedBindings = [...importedBindings, ...checked];
    importedDataDecls = [...importedDataDecls, ...produced.dataDecls];
    runningEnv = TopEnv(importedBindings, importedDataDecls);
  }
  _importStack.removeLast();

  // 5. Merge into calling env (duplicate detection)
  for (final b in importedBindings) {
    final existing = topEnv.bindings.indexedFirstWhere(...);
    if (existing != null) {
      if (identical(existing.type, b.type) && identical(existing.term, b.term)) {
        continue; // identical — idempotent import
      }
      throw DuplicateDeclaration(b.name, span);
    }
  }
  for (final d in importedDataDecls) {
    final existing = topEnv.dataDecls.indexedFirstWhere(...);
    if (existing != null) {
      if (identical(existing, d)) continue;
      throw DuplicateDeclaration(d.name, span);
    }
  }

  // 6. Return merged env
  return (
    bindings: [...topEnv.bindings, ...importedBindings],
    dataDecls: [...topEnv.dataDecls, ...importedDataDecls],
    corecursiveGroup: null,
    metas: MetaContext(),
  );
}
```

#### 1b. Path resolution

```dart
/// Resolve an import path relative to the current file's directory.
String _resolveImportPath(String importPath, String currentFile) {
  final currentDir = Directory(currentFile).parent.path;
  return normalize(join(currentDir, importPath));
}
```

For the initial implementation, require paths to be resolvable from the current
working directory. Absolute paths are supported. No `lib/stdlib/` search path yet.

#### 1c. Cyclic import detection

```dart
/// Stack of currently-being-processed import paths, for cycle detection.
final _importStack = <String>[];
```

---

### Step 2 — CLI and test harness updates (~30 lines)

#### 2a. CLI (`doxa_tooling/bin/doxa.dart`)

In `checkSource`:
- The prelude is still auto-loaded before user code.
- User code can now contain `import` directives — the elaborator handles them during
  `_elabDecl`.
- No changes to the check pipeline itself — `elabDecl` + `checkDeclResult` already
  handle the merged `TopEnv` returned by `_processImport`.

#### 2b. Test harness (`doxa_tooling/test/stdlib_test.dart`)

Update the test infrastructure:
- Split monolithic stdlib files into per-module files (see Step 4).
- Tests check individual modules with their imports.
- The main `proofs.doxa` becomes a file that imports shared modules.

#### 2c. New test: import resolution

Create `doxa_tooling/test/import_test.dart`:
- Test that `import "stdlib/nat.doxa"` makes `Nat` available.
- Test that importing duplicate names raises `DuplicateDeclaration`.
- Test cyclic import detection.
- Test that non-imported names are not accessible.

#### 2d. Error types

Add to `check.dart` or `elab.dart`:
```dart
final class CyclicImport extends ElabError {
  final String path;
  const CyclicImport(this.path, this.span);
}

final class ImportFileNotFound extends ElabError {
  final String path;
  const ImportFileNotFound(this.path, this.span);
}
```

---

### Step 3 — Kernel: no changes needed

The kernel already handles `TopEnv` merging (bindings + dataDecls).
`TTop(name)` resolution is flat — no namespace qualification.
No kernel changes required for Phase 18.

---

### Step 4 — Stdlib reorganisation (~40 lines)

#### 4a. Split monolithic files

Current: each stdlib file is self-contained (duplicates `data Nat`, `data Bool`, etc.)

After reorganisation:

| File | Imports | Exports |
|------|---------|---------|
| `prelude.doxa` | — | `Eq` |
| `bool.doxa` | — (imports prelude implicitly) | `Bool`, `and_`, `or_`, `not_` |
| `nat.doxa` | — (imports prelude implicitly) | `Nat`, `plus`, `mult`, `pow`, `leq` |
| `list.doxa` | `import "nat.doxa"`, `import "bool.doxa"` | `List`, `map`, `fold`, `append` |
| `option.doxa` | — | `Option`, `map`, `getOrElse` |
| `vec.doxa` | `import "nat.doxa"` | `Vec`, `vhead`, `vappend` |
| `eq.doxa` | — | `sym`, `trans`, `cong`, `subst` |
| `proofs.doxa` | `import "nat.doxa"`, `import "list.doxa"`, `import "vec.doxa"`, `import "eq.doxa"` | All proofs |

Remove duplicate `data Nat`, `data Bool`, etc. from `list.doxa`, `vec.doxa`, `proofs.doxa`.
Replace with `import` statements at the top of each file.

#### 4b. Update `example/proofs.doxa`

Add `import "stdlib/nat.doxa"` and other necessary imports at the top.
Remove duplicate data declarations.

---

### Step 5 — Tooling updates (~20 lines)

#### 5a. `DoxaToken` (syntax.dart)
Add `kwImport` for the `import` keyword.

#### 5b. `DoxaSyntax` (syntax.dart)
Add `importDecl` for CST green-node construction.

#### 5c. `parse_tree.dart`
Add `SImportKind _ => DoxaSyntax.importDecl` in `_buildDeclNode`.

#### 5d. `web_check.dart`
Add mapping for new error kinds (`CyclicImport`, `ImportFileNotFound`).

#### 5e. `reparsableKinds` (syntax.dart)
Add `DoxaSyntax.importDecl` so incremental reparsing works.

#### 5f. Reserved words (parse.dart)
Add `"import"` to `_keyword` if not already a reserved word.

---

### Step 6 — Tests (~80 lines)

Create `doxa_tooling/test/import_test.dart`:

| # | Test | Expected |
|---|------|----------|
| 1 | `import "stdlib/nat.doxa"` makes `Nat` available | `Nat` type-checks |
| 2 | Importing a file twice is idempotent | No error |
| 3 | `import` of non-existent file → error | `ImportFileNotFound` |
| 4 | Cyclic import (A imports B, B imports A) → error | `CyclicImport` |
| 5 | Duplicate declaration (different body, same name) → error | `DuplicateDeclaration` |
| 6 | Self-import (file imports itself) → error | `CyclicImport` |
| 7 | `import` paths resolve relative to importing file | Names accessible |
| 8 | Regression: all existing stdlib tests pass after reorganisation | All 424 tooling tests pass |

---

### Step 7 — Exit verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All existing tests pass (413 doxa + 424 doxa_tooling + new import tests).
Stdlib files are reorganised with imports.
`proofs.doxa` type-checks using imported shared modules.
No duplicate declarations remain in stdlib files.

---

## Files to modify

| File | Changes | Est. lines |
|------|---------|-----------|
| `doxa/lib/src/surface.dart` | `SImportKind` class | +15 |
| `doxa/lib/src/parse.dart` | `_importDecl` + `_strLit` parser | +15 |
| `doxa/lib/src/elab.dart` | `_processImport`, `SImportKind` case, `_importStack`, `_resolveImportPath` | +50 |
| `doxa/lib/src/check.dart` | `CyclicImport`, `ImportFileNotFound` error types | +15 |
| `doxa_tooling/lib/src/syntax.dart` | `kwImport`, `importDecl` syntax kinds | +5 |
| `doxa_tooling/lib/src/parse_tree.dart` | `SImportKind → DoxaSyntax.importDecl` | +2 |
| `doxa_tooling/lib/src/web_check.dart` | New error kind mappings | +4 |
| `doxa_tooling/bin/doxa.dart` | Possibly minor | +2 |
| `lib/stdlib/*.doxa` | Reorganise: remove duplicates, add imports | +20 |
| `example/proofs.doxa` | Add imports, remove duplicates | +10 |
| `doxa_tooling/test/import_test.dart` | **New file** — 8 tests | +60 |
| `doxa_tooling/test/stdlib_test.dart` | Adapt to reorganised stdlib | +5 |
| **Total** | | **~203** |

---

## Risk assessment

**Risk: Medium.** Import resolution touches every phase of the pipeline — parser,
elaborator, CLI, tests, and stdlib files. The largest risk is breaking existing
stdlib tests by introducing import statements that can't resolve at test time
(the test working directory differs from the CLI working directory).

**Mitigations:**
1. Import paths resolve relative to the importing file's directory, not the CWD.
   Tests can use relative paths from `lib/stdlib/`.
2. The prelude remains auto-loaded — no user-facing change for single-file programs.
3. `import` is an additive feature — existing code without imports works unchanged.
4. Duplicate detection is lenient: identical declarations are silently accepted
   (idempotent import), preventing errors when the same module is imported
   transitively multiple times.
