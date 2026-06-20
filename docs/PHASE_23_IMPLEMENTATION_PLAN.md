# Phase 23 — Namespace-Qualified Modules

## Goal

`Nat.plus` resolves to `plus` in module `Nat` without polluting the flat
namespace. Selective imports keep current ergonomics; qualified names
remove collision risk as the stdlib expands.

## Why First

Phase 18 (imports) uses a flat namespace: every imported name is visible
unqualified. As the stdlib expands, name collisions become inevitable
(`plus` in `Nat` and `Int`). Namespace qualification gates safe stdlib
expansion (Phase 25).

## Current State

The module system is Phase 18 complete: imports work, cycle detection
works, transitive imports work, selective imports work. But it is a
**flat namespace**: every imported name is visible unqualified; dots are
purely a naming convention. `Nat.rec` is stored as the single flat string
key `"Nat.rec"` in `topBindings`.

Key observations:
1. `SDotKind` already exists in the surface AST for dotted names
   (`Nat.plus` parses as `SDot(SIdent("Nat"), "plus")`).
2. `_flattenDottedIdent` collapses dot chains into flat strings.
3. `TTop` has no namespace field — just `final String name`.
4. `Env.topBindings` is a flat `Map<String, TopBindingEntry>`.
5. The `_processImport` pipeline already handles file loading,
   elaboration, cycle detection, and selective imports.
6. Recursors already use dotted flat keys: `Nat.rec`, `Nat.rect`.

## Design Decisions

**Zero kernel changes.** The approach works entirely at the elaboration
level. No new term forms, no changes to `eval.dart`, `conv.dart`, or
`check.dart`. `TTop` remains unchanged.

**Dual registration.** Each imported binding is registered in TWO places:
1. The flat `topBindings` map (unqualified — existing behaviour)
2. A new `namespaceBindings` map (qualified — prefix → unqualified name
   → entry)

**Resolution order for `DotQual.ifIer.name`:**
1. Record projection (existing — first priority)
2. Namespace-qualified lookup (new — try `namespaceBindings`)
3. Flatten-to-dotted-string then flat lookup (existing — backward compat,
   catches any remaining dotted-flat keys like old-style `Nat.rec`)

**Kernel term.** Namespace-resolved references produce `TTop(unqualifiedName)`
— the bare name, not the dotted string. At eval time, `topBindings`
provides the entry via unqualified key.

## Deliverables

1. `import "nat.doxa"` makes names available unqualified (current
   behaviour) **and** qualified as `Nat.<name>`.
2. `import "nat.doxa" as N` creates alias `N.<name>` (replaces
   auto-derived prefix).
3. Duplicate unqualified names error; qualified names never collide.
4. Existing 885 tests pass unchanged.
5. New tests for: qualified access, `as` alias, cross-module qualifier
   disambiguation, duplicate rejection.

## Step-by-Step Implementation

### Step 1 — Surface AST: `SImportKind.alias`

**File:** `doxa/lib/src/surface.dart` (lines 526-555)

Add an optional `alias` field:

```dart
final class SImportKind extends SDeclKind {
  final String path;
  final List<String> importedNames;
  final String? alias;  // NEW: for `import "path" as Alias`

  const SImportKind(this.path, {
    this.importedNames = const [],
    this.alias,
  });
  // ...
}
```

Update `==`, `hashCode`, `toString` to include `alias`.

### Step 2 — Parser: `import "path" as Alias`

**File:** `doxa/lib/src/parse.dart` (lines 152-170)

Extend `_importDecl` to parse optional `as` clause:

```
import "path/to/file.doxa"                → alias is null
import "path/to/file.doxa" as N           → alias is "N"
import "path/to/file.doxa" { a, b } as N  → selective + alias
```

The `as` keyword + identifier comes AFTER the optional brace block.
Parser combinator:

```dart
final asAlias = _keyword('as').skipThen(_ident);
```

Add it to the chain after the brace block. Handle all three positions:
- `import "p"` → alias null, importedNames []
- `import "p" { a }` → alias null, importedNames [a]
- `import "p" as N` → alias "N", importedNames []
- `import "p" { a } as N` → alias "N", importedNames [a]

### Step 3 — Module name derivation

**File:** `doxa/lib/src/elab.dart` (new helper function)

Helper to derive module name from an import path:

```dart
/// Derive module prefix from file path: "nat.doxa" → "Nat",
/// "foo/bar.doxa" → "Bar".
String _modulePrefix(String path) {
  final filename = path.split('/').last.split('\\').last;
  final stem = filename.endsWith('.doxa')
      ? filename.substring(0, filename.length - '.doxa'.length)
      : filename;
  if (stem.isEmpty) return stem;
  return stem[0].toUpperCase() + stem.substring(1);
}
```

### Step 4 — `TopEnv` gains namespace index

**File:** `doxa/lib/src/elab.dart` (lines 894-1009, TopEnv class)

Add a `namespaceBindings` field:

```dart
final class TopEnv {
  final List<TopBinding> bindings;
  final List<DataDecl> dataDecls;
  final Map<String, ClassInfo> classRegistry;
  final Map<String, Map<String, TopBindingEntry>> namespaceBindings; // NEW

  const TopEnv(
    this.bindings, [
    this.dataDecls = const <DataDecl>[],
    this.classRegistry = const {},
    this.namespaceBindings = const {}, // NEW
  ]);
  // ...
}
```

Update all `TopEnv(...)` construction sites throughout `elab.dart` and
`doxa.dart` to pass `namespaceBindings`. The empty map `{}` works
everywhere — it only gets populated during import processing.

Update `TopEnv.empty` to include the new field.

**Lookup helper** on `TopEnv`:

```dart
/// Look up a name qualified by namespace prefix.
/// Returns the [TopBindingEntry] if found, or null.
TopBindingEntry? lookupQualified(String namespace, String name) {
  return namespaceBindings[namespace]?[name];
}
```

### Step 5 — `_processImport` registers qualified names

**File:** `doxa/lib/src/elab.dart` (lines 3233-3354)

The key change. After the existing logic that produces `localBindings` and
`localDataDecls`:

1. Compute module prefix:
   - If `alias` is non-null: use alias
   - Otherwise: derive from path using `_modulePrefix(path)`

2. For each `TopBinding` in `localBindings`, register in the namespace
   map under the module prefix.

3. For each `DataDecl` in `localDataDecls`, register its names in the
   namespace map.

The registration happens at the `DeclResult` level — the new `namespaceBindings`
map is part of the returned record.

**`DeclResult` addition:**

Add `namespaceBindings` to the `DeclResult` typedef (the anonymous record
type returned by `_elabDecl` / `_processImport` / `checkDeclResult`):

```dart
// In the record type definition (search for `({...})` pattern)
// Add: Map<String, Map<String, TopBindingEntry>> namespaceBindings,
```

**In `_processImport`:**

After the `if (importedNames.isNotEmpty)` selective-filter block, but
before the duplicate check, compute and populate the namespace map:

```dart
// Compute module prefix
final modPrefix = alias ?? _modulePrefix(path);

// Build namespace entries
final nsMap = <String, Map<String, TopBindingEntry>>{};
nsMap[modPrefix] = {};
for (final b in localBindings) {
  // The actual TopBindingEntry will be computed later during toCtx().
  // We store the name → entry via the existing checkDeclResult pipeline.
  // For now, just record the (type, value) that will be finalized.
}
```

**Correction:** The `TopBindingEntry` is computed in `TopEnv.toCtx()` and
`checkDeclResult`. For the namespace map, we need to register the entries
that `checkDeclResult` will eventually produce. The simplest approach:

After `checkDeclResult` returns (line 3307 in the current `_processImport`),
the `localBindings` list has been finalized with `checkDeclResult`. But
`checkDeclResult` takes a `TopEnv` and runs eval on the bindings' terms.
The namespace entries need the same evaluated types/values.

**Better approach:** Don't put namespace entries in `DeclResult`. Instead,
build the namespace map at the `checkSource` level (in `doxa.dart`) by
augmenting the `TopEnv` after each import declaration. This way the
namespace map is built incrementally alongside bindings and dataDecls.

In `checkSource` (doxa.dart lines 252-270), after processing an import:

```dart
if (decl.kind is SImportKind) {
  // Merge namespace bindings from the import
  final importKind = decl.kind as SImportKind;
  final modPrefix = importKind.alias ?? _modulePrefix(importKind.path);
  // Compute entries from the finalized (checkDeclResult-processed) bindings
  // ...
}
```

But `checkSource` is in `doxa_tooling/bin/doxa.dart` which is a consumer
of the kernel. The namespace logic should live in the elaborator.

**Final approach:** The `_processImport` function already builds and
returns bindings. After `checkDeclResult`, those bindings are finalized
with the correct terms and spans. We can compute namespace entries at
that point by evaluating the binding types using a temporary `TopEnv`
with the accumulated state.

Actually, let me look at this more carefully. In `_processImport`:

```dart
for (final decl in prog.decls) {
  final runningEnv = TopEnv(
    [...topEnv.bindings, ...localBindings],
    [...topEnv.dataDecls, ...localDataDecls],
  );
  final produced = _elabDecl(runningEnv, decl);
  // ...
  final finalized = checkDeclResult(checkEnv, produced);
  localBindings = [...localBindings, ...finalized];
  localDataDecls = runningData;
}
```

The finalized bindings have their terms and types as elaborated `Term`
objects. The `TopBindingEntry` (with evaluated `Value` type and value)
is computed later in `TopEnv.toCtx()`. So the namespace map can't store
`TopBindingEntry` at `_processImport` time — it needs to be computed
alongside `toCtx()`.

**Simplest correct approach:**

Store raw `TopBinding` references in the namespace map (not
`TopBindingEntry`), and do namespace-aware lookup in `_inferExpr` by
accessing the binding's type/term directly. But `TopBinding.term` is a
`Term`, not a `Value`, and we need the evaluated type for inference.

**Alternative:** Have `_processImport` return namespace entries as
`(String prefix, Set<String> names)` — just the metadata about which
names belong to which namespace. The actual `TopBindingEntry` lookup for
namespace-qualified names can go through a helper that:
1. Finds which namespace the prefix maps to
2. Looks up the unqualified name in `topBindings`

This approach requires NO changes to `TopBindingEntry` or the eval
pipeline. The namespace map is just `Map<String, Set<String>>` — prefix →
set of unqualified names available under that prefix.

In `_inferExpr`:
```dart
// Namespace-qualified lookup
if (topEnv.lookupQualified(qualifierName, name) != null) {
  // The name is known to be in that namespace. Look it up in topBindings.
  final entry = state.ctx.env.lookupTop(name);
  // ...
  return (TTop(name), entry.type);
}
```

This is clean. Let me go with this:

**Namespace map type:** `Map<String, Set<String>>` in `TopEnv`
- Maps namespace prefix → set of unqualified names
- Cheap to build, no duplication of entries
- Lookup is: check if prefix exists in map AND name is in its set →
  then do normal topBindings lookup for the entry

### Step 6 — SDotKind resolution in `_inferExpr`

**File:** `doxa/lib/src/elab.dart` (lines 1503-1562)

The SDotKind case currently has three paths:
1. Record projection (try first)
2. Flatten dotted to flat string, then lookup

Add a NEW path between them: namespace-qualified lookup.

```dart
case SDotKind(:final qualifier, :final name):
  // 1. Try record projection (existing)
  try { ... } catch (_) {}

  // 2. Try namespace-qualified lookup (NEW)
  if (qualifier.kind is SIdentKind) {
    final qualName = (qualifier.kind as SIdentKind).name;
    if (topEnv.lookupQualified(qualName, name) != null) {
      // Name is available qualified. Resolve via flat topBindings.
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

  // 3. Flatten to dotted string and lookup (existing fallback)
  final flat = _flattenDottedIdent(expr);
  // ...existing code...
```

### Step 7 — Recursors registered under namespace

**File:** `doxa/lib/src/elab.dart` (`_emitRecursors`, lines 4432-4504)

Currently recursors are registered as `"Nat.rec"` in the flat
`topBindings` map. With namespace-qualified resolution, `Nat.rec` can
be resolved via the namespace map. But we still register the dotted-flat
key for backward compatibility.

Add recursor names to the namespace map. This requires the data
declaration's name to be available as a namespace prefix. When a
`data Nat` is declared, `Nat` should become a namespace prefix for
its auto-generated bindings (`Nat.rec`, `Nat.rect`).

**Implementation:** After `unsugarDataRecursors` produces bindings,
collect the data name as a namespace prefix and the recursor names.
This can be done in `_elabDecl` for `SDataKind`:

```dart
case SDataKind(...):
  // ...existing elaboration...
  // Add recursor names to namespace map
  final nsMap = <String, Set<String>>{};
  nsMap[name] = {
    for (final b in produced.bindings) b.name,
  };
  return (
    bindings: produced.bindings,
    dataDecls: produced.dataDecls,
    namespaceBindings: nsMap,
    // ...
  );
```

But wait — `produced` is a `DeclResult` which needs the new
`namespaceBindings` field.

### Step 8 — `DeclResult` gains `namespaceBindings`

**File:** `doxa/lib/src/elab.dart`

The anonymous record type returned by declarative elaboration functions
needs a new field. The type appears in the return type of `_elabDecl`,
`elabDecl`, `checkDeclResult`, `_processImport`, `_elabFunBlock`, etc.

Search for `({` patterns used as record return types and add
`namespaceBindings` everywhere. The field carries
`Map<String, Set<String>>`.

**Checklist of functions returning DeclResult:**
- `elabDecl` (public API, ~line 2820)
- `_elabDecl` (~line 2850)
- `checkDeclResult` (~line 2240)
- `_processImport` (~line 3240)
- `_elabFunBlock`
- `_elabTypeclassDecl`

Each needs the field added to its return record and propagated.

### Step 9 — Pipeline integration in `checkSource`

**File:** `doxa_tooling/bin/doxa.dart` (lines 221-299)

The `checkSource` pipeline accumulates `bindings` and `dataDecls`. Now
also accumulate `namespaceBindings`:

```dart
var namespaceBindings = <String, Set<String>>{};

for (final decl in program.decls) {
  final env = TopEnv(bindings, dataDecls, classRegistry, namespaceBindings);
  // ...existing processing...
  namespaceBindings = _mergeNamespace(namespaceBindings, produced.namespaceBindings);
}
```

Also update `TopEnv(...)` construction to pass the accumulated
`namespaceBindings`.

`_mergeNamespace` helper:
```dart
Map<String, Set<String>> _mergeNamespace(
  Map<String, Set<String>> a,
  Map<String, Set<String>> b,
) {
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

### Step 10 — import `as` with `_processImport`

**File:** `doxa/lib/src/elab.dart`

Pass `alias` through to `_processImport` from `_elabDecl`:

```dart
case SImportKind(:final path, :final importedNames, :final alias):
  return _processImport(topEnv, path, decl.span,
    importedNames: importedNames,
    alias: alias,
  );
```

In `_processImport`, compute module prefix using alias if provided:

```dart
final modPrefix = alias ?? _modulePrefix(path);
```

### Step 11 — Tests

**New file:** `doxa_tooling/test/namespace_test.dart`

Tests:
1. `Nat.zero` resolves — basic qualified access
2. `Nat.plus zero zero` — qualified name in application
3. `import "nat.doxa" as M` — alias-based qualified access `M.zero`
4. Unqualified `zero` still works — backward compat
5. Two modules with same unqualified name — duplicate error fires
6. Same name in two namespaces — `Nat.plus` and `Int.plus` both work
7. Nested module reference `A.B.c` — three-level dotted chain
8. Qualified name in type annotation `val x : Nat.Nat`
9. Recursor via qualified name: `Nat.rec` still works
10. Selective import with qualified access

**Update existing tests if needed:**
- `dotted_name_test.dart` — may need updates if resolution changes
- `import_test.dart` — add namespace-qualified tests

### Step 12 — Verify

```bash
dart analyze doxa/
dart analyze doxa_tooling/
dart run doxa_tooling:test -r expanded
dart format --set-exit-if-changed doxa/ doxa_tooling/
dart run doxa_tooling:bin/doxa check example/proofs.doxa
dart run doxa_tooling:bin/doxa check lib/stdlib/proofs.doxa
```

All 885 existing tests must continue to pass.

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `doxa/lib/src/surface.dart` | `SImportKind.alias` field | ~5 |
| `doxa/lib/src/parse.dart` | Parse `as` clause in imports | ~15 |
| `doxa/lib/src/elab.dart` | `TopEnv.namespaceBindings` + methods | ~30 |
| `doxa/lib/src/elab.dart` | `_modulePrefix` helper | ~10 |
| `doxa/lib/src/elab.dart` | `_inferExpr` SDotKind: namespace lookup | ~20 |
| `doxa/lib/src/elab.dart` | `_processImport`: namespace registration | ~20 |
| `doxa/lib/src/elab.dart` | `_elabDecl` SDataKind: recursor namespace | ~10 |
| `doxa/lib/src/elab.dart` | All `DeclResult` record types: add field | ~20 |
| `doxa_tooling/bin/doxa.dart` | Pipeline: accumulate namespaceBindings | ~15 |
| `doxa_tooling/test/namespace_test.dart` | New test file | ~150 |
| **Total** | | **~295 lines** |

## Risks

1. **`DeclResult` record type propagation.** Adding a field to the
   anonymous record type requires updating every function that returns
   it. Missing one produces a Dart type error at the call site.
   Mitigation: `dart analyze` catches every missing field immediately.

2. **Namespace collapse on nested imports.** When module A imports
   module B, B's names are registered under B's prefix. If A is then
   imported by C, C should see B's names under B's prefix (not A.B).
   This is naturally handled because `_processImport` registers each
   module's own namespace prefix from its own path.

3. **Recursor naming collision.** `Nat.rec` is already a flat key in
   topBindings. With namespace-qualified resolution, `Nat.rec` resolves
   via the namespace map for `Nat` → `rec`. The dotted-flat key
   `"Nat.rec"` in topBindings may or may not exist depending on whether
   we register it. The fallback flatten-and-lookup ensures backward
   compatibility.

## Exit Criteria

- [ ] `import "nat.doxa"` — `Nat.zero` resolves
- [ ] `import "nat.doxa" as M` — `M.zero` resolves
- [ ] Unqualified `zero` still works (backward compat)
- [ ] Duplicate unqualified `plus` from two modules errors
- [ ] `Nat.plus` and `Int.plus` coexist (qualified disambiguation)
- [ ] All 885 existing tests pass
- [ ] `dart analyze` 0 issues
- [ ] `dart format` clean
- [ ] `example/proofs.doxa` type-checks
- [ ] `lib/stdlib/proofs.doxa` type-checks
