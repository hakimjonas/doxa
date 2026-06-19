# Phase 21.5 — Surface Syntax Alignment (Doxa → Fungal)

Five cosmetic sugar changes closing the remaining gap between Doxa's surface
syntax and Fungal's. All are parser/elaborator sugar — no kernel changes.
~80 lines, 3-4 sessions.

---

## Item 1 — `fun` Body Braces (~10 lines)

### Current

```
fun add(x: Int, y: Int): Int = x + y
```

### Target (Fungal-compatible)

```
fun add(x: Int, y: Int): Int { x + y }
```

### Why

Fungal uses block bodies for `fun`. Doxa uses `= expr`. This is the single
most visible syntax difference. Supporting braces reduces friction for users
moving between the two languages.

### Implementation

**File:** `doxa/lib/src/parse.dart` — the `_mkFunBody` parser (line ~858).

Currently: after parsing return type + `{struct}` annotation, the parser
expects `= expr`:

```dart
_sym('=').skipThen(_expr)
```

Change to accept both `= expr` and `{ expr }`:

```dart
(_sym('=').skipThen(_expr) |
 _sym('{').skipThen(_expr).thenSkip(_sym('}')))
```

The block `{ expr }` is a single expression terminated by `}`. If the body
contains local bindings (e.g., `{ val x = 1; x + 1 }`), the brace block is
already a `_blockExpr` atom, so `_expr` already handles it.

No elaborator change needed — the body is an `SExpr` either way.

### Test

| # | Test | Expected |
|---|------|----------|
| 1 | `fun f(): Nat { zero }` | Parses, type-checks, evaluates correctly |
| 2 | `fun f(): Nat = zero` | Still works (backward compat) |
| 3 | `fun f(): Nat { val x = zero; x }` | Block-expr body with local bindings |
| 4 | Regression: all existing `fun` definitions pass | No breakage |

---

## Item 2 — `data` Product Form (~15 lines)

### Current

Single-ctor `data` declarations are the only way to define record-like types:

```
data Point[A B: Type] : Type {
  mk : A -> B -> Point A B;
}
```

Field access uses `p.fst` via Phase 17 primitive projections, but the
declaration syntax doesn't visually distinguish a product from a sum.

### Target (Fungal-compatible)

```
data Point[A B: Type] : Type {
  x: A;
  y: B;
}
```

A product form: no constructor keyword, just named fields with types.
Desugars to a single-ctor `data` with an auto-generated constructor.

### Implementation

**File:** `doxa/lib/src/parse.dart` — the `_dataDecl` parser.

Currently `_dataDecl` expects `{ _ctorDecl* }` (semicolon-separated constructor
signatures). Change to accept EITHER constructor signatures OR field declarations:

A field declaration is: `name: Type;` (no `->` chain, no arrow to the data type).

Detection: if the first item after `{` is `_ident` followed by `:` and `_expr`
but the expression is NOT followed by `->` or another `:` (i.e., it's NOT a
constructor Pi type), it's a field declaration → product form.

Simpler heuristic: if the first "ctor" entry has no result type (no `->` chain
leading to the inductive type's name), AND it's not followed by `;` that precedes
another ctor-like entry, it's a product.

Easiest approach: add a `_fieldDecl` parser that matches `name: Type;` and
a `_productDataDecl` parser that matches `{ _fieldDecl* }`. The product form
desugars in the parser to a `SDataKind` with a single synthesized constructor.

**File:** `doxa/lib/src/elab.dart` — `_elabData`.

When a product data is detected, synthesize a single constructor `mk` with
the field types as arguments:

```dart
// Product form: data Point { x: A; y: B }
// desugars to: data Point : Type { mk : A -> B -> Point; }
// with primitive projections enabled automatically
```

The field names become the projection names. Phase 17 already enables
primitive projections for single-ctor data types.

### Test

| # | Test | Expected |
|---|------|----------|
| 1 | `data Pair { fst: A; snd: B }` | Parses, constructs with `mk a b`, `p.fst` works |
| 2 | `data Point { x: Int; y: Int }` | Product with primitive projections |
| 3 | Existing sum `data Nat : Type { zero; succ }` | Unchanged, backward compat |
| 4 | Error: product with no fields | Rejected gracefully |

---

## Item 3 — `|` Variant Separator (~10 lines)

### Current

```
data Option[A: Type] : Type {
  none : Option[A];
  some : A -> Option[A];
}
```

Constructors separated by `;`.

### Target (Fungal-compatible)

```
data Option[A: Type] : Type {
  none: Option[A]
  | some: A -> Option[A]
}
```

Constructors separated by `|` (optional `;`). Fungal uses `|` between
constructors and requires no trailing separator. Doxa currently uses `;`.

### Implementation

**File:** `doxa/lib/src/parse.dart` — the `_ctorDecl` list parser inside `_dataDecl`.

Currently uses `sepBy(_sym(';'))`. Change to accept `|` as alternative
separator, or make `|` the primary with `;` as fallback:

```dart
// Accept | or ; as constructor separator in data bodies
final _ctorSep = _sym('|') | _sym(';');
```

Change `_ctorDecl` list to `sepBy(_ctorSep)`.

Each constructor ends with `;` in the current syntax. With `|`, the separator
moves to BETWEEN constructors (like Fungal). This is purely a parser change —
the separator is already discarded after parsing.

### Test

| # | Test | Expected |
|---|------|----------|
| 1 | `data T { A: T | B: T }` | Parses with `\|` separator |
| 2 | `data T { A: T; B: T }` | Still works with `;` separator |
| 3 | Existing stdlib `data` declarations | Unchanged (still use `;`) |

---

## Item 4 — Selective Import (~20 lines)

### Current

```
import "stdlib/nat.doxa"
```

Imports EVERYTHING from the module — all top-level names become available.

### Target (Fungal-compatible)

```
import "stdlib/nat.doxa" { plus, mult, zero }
```

Selective import: only the named bindings are imported. Equivalent to Fungal's
`import Math.{add, subtract}`.

### Implementation

**Files:**
- `doxa/lib/src/parse.dart` — extend `_importDecl` to accept optional `{ name, ... }` suffix
- `doxa/lib/src/surface.dart` — add `importedNames` field to `SImportKind`
- `doxa/lib/src/elab.dart` — `_processImport` filters bindings by `importedNames` if non-empty

**Parser:**

After the path string, accept optional `{ _ident (',' _ident)* }`:

```dart
final Parser<ParseError, SDecl> _importDecl = position<ParseError>().flatMap(
  (start) => _keyword('import')
      .skipThen(_strLit)
      .flatMap(
        (path) => _sym('{')
            .skipThen(_ident.sepBy(_sym(',')))
            .thenSkip(_sym('}'))
            .optional
            .zip(position<ParseError>())
            .map((pair) => SDecl(
              SImportKind(path, importedNames: pair.$1 ?? []),
              DoxaSpan(start, pair.$2),
            )),
      ),
);
```

**Surface AST:**

```dart
final class SImportKind extends SDeclKind {
  final String path;
  final List<String> importedNames;  // empty = import all
  const SImportKind(this.path, {this.importedNames = const []});
  // update ==, hashCode, toString
}
```

**Elaborator:**

In `_processImport`, after collecting local bindings, filter:

```dart
if (importedNames.isNotEmpty) {
  localBindings = localBindings
      .where((b) => importedNames.contains(b.name))
      .toList();
  localDataDecls = localDataDecls
      .where((d) => importedNames.contains(d.name))
      .toList();
}
```

### Test

| # | Test | Expected |
|---|------|----------|
| 1 | `import "nat.doxa" { plus }` | Only `plus` available, `mult` not in scope |
| 2 | `import "nat.doxa"` | All names available (backward compat) |
| 3 | `import "nat.doxa" { bogus }` | Error: bogus not in module |
| 4 | `import "nat.doxa" { plus, mult }` | Both available, others not |

---

## Item 5 — Optional Type Parameter Kinds (~10 lines)

### Current

```
fun identity[A: Type](x: A): A = x
```

Type parameters MUST have an explicit kind annotation (`: Type`).

### Target

```
fun identity[A](x: A): A = x
```

Type parameter kinds are optional — bare `[A]` defaults to `Type`.

### Implementation

**File:** `doxa/lib/src/parse.dart` — the `_funTypeParams` / `_typeParams` parsers.

Currently:

```dart
_ident.flatMap((name) => _sym(':').skipThen(_expr).map((kind) => (name, kind)))
```

The `: Type` part is required. Make the kind annotation optional and default
to a bare `Type` when omitted:

```dart
_ident.flatMap((name) =>
    _sym(':').skipThen(_expr).optional.map((kind) =>
        (name, kind ?? SExpr(SIdentKind('Type'), DoxaSpan.synthetic))
    )
)
```

This applies to:
- `fun` type params `[A]` / `[A: Type]`
- `data` type params `[A]` / `[A: Type]`
- Implicit type params `{A}` / `{A: Type}`

### Test

| # | Test | Expected |
|---|------|----------|
| 1 | `fun id[A](x: A): A = x` | Parses, `A` defaults to `Type` |
| 2 | `fun id[A: Type](x: A): A = x` | Still works (explicit kind) |
| 3 | `data List[A] : Type { ... }` | Parses without explicit `: Type` |
| 4 | `fun constrained[A: Prop](p: A): A = p` | Explicit non-Type kind still works |

---

## Verification

```shell
cd doxa               && dart analyze lib/ test/ && dart test
cd doxa_tooling       && dart analyze lib/ bin/ test/ && dart test
```

All 418 doxa tests pass. All 444 doxa_tooling tests pass.
Existing stdlib files continue to parse and type-check with their current
syntax. New syntax forms are additive only.

---

## Files to modify

| Item | File | Changes | Est. lines |
|------|------|---------|-----------|
| 1 | `doxa/lib/src/parse.dart` | Brace body in `_mkFunBody` | +3 |
| 2 | `doxa/lib/src/parse.dart` | `_productDataDecl` + `_fieldDecl` parsers | +10 |
| 2 | `doxa/lib/src/elab.dart` | Product data desugaring in `_elabData` | +5 |
| 3 | `doxa/lib/src/parse.dart` | `|` separator in ctor list | +2 |
| 4 | `doxa/lib/src/parse.dart` | Selective import `{ names }` suffix | +5 |
| 4 | `doxa/lib/src/surface.dart` | `importedNames` on `SImportKind` | +5 |
| 4 | `doxa/lib/src/elab.dart` | Filter bindings in `_processImport` | +5 |
| 5 | `doxa/lib/src/parse.dart` | Optional kind in `_typeParams` variants | +5 |
| — | `doxa_tooling/lib/` | Update exhaustive switches if needed | +5 |
| — | `doxa_tooling/test/` | New tests for each item | +30 |
| **Total** | | **~75** |

## Risk assessment

**Risk: Very Low.** All five items are purely additive sugar:
- Item 1: alternation in parser — `= expr | { expr }`
- Item 2: new parser path for product data — desugars to existing single-ctor form
- Item 3: alternative separator — `; | |`
- Item 4: filter on imported names — doesn't change resolution, only visibility
- Item 5: default value for missing kind — `Type` when omitting `: Type`

No kernel changes. No existing behavior changes. No stdlib changes required
(existing syntax remains valid).
