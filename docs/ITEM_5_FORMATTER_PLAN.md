# Item 5 — Formatting (`doxa fmt`)

## Goal

A canonical code formatter for Doxa source files. `doxa fmt FILE` reads
a `.doxa` file, formats it to the canonical style, and writes the result
back (or to stdout with `--check` / `--stdout`). Idempotent: formatting
already-formatted code is a no-op.

## Why

Formatting eliminates style debates, makes diffs minimal, and produces code
that looks the same across all Doxa projects. The canonical style is
designed to be portable to Fungal (both languages share surface syntax
conventions), so a future self-hosted Fungal formatter can reuse these
decisions.

## Canonical Style

### Spacing
- **Indent:** 2 spaces per level (never tabs)
- **Line width:** 100 characters soft limit (expressions may exceed it;
  the formatter prefers splitting at declaration/block boundaries)
- **Trailing whitespace:** stripped (no trailing spaces or tabs)
- **File ending:** exactly one trailing newline
- **Blank lines:** at most 1 between declarations; leading/trailing blank
  lines stripped from the file

### Braces
- **K&R style:** opening brace on the same line as the keyword or
  expression that introduces the block, preceded by a space
- **Closing brace** on its own line at the same indent as the construct
  that opened it
- **Empty blocks** on one line: `{ }`

### Semicolons
- **Required** between items in block expressions and between
  constructors in `data` declarations
- The formatter **inserts** missing semicolons (this is a "fix",
  not just formatting — the source is semantically incomplete without
  them)

### Declarations

**`val`:**
```
val name : Type = expr
val name = expr              // inferred type
```
When the expression is long, it hangs to the next line at +2:
```
val longName : SomeLongType =
  someLongExpression arg1 arg2
```

**`fun` (single-expression body):**
```
fun name[TypeParams](args): ReturnType = expr
```
Multi-parameter wrapping: each parameter group on its own line at +2.
The `=` stays on the same line as the return type.

**`fun` (multi-expression body):**
```
fun name[TypeParams](args): ReturnType {
  val x = e;
  result
}
```
The `{` is on the same line as the return type. Each binding gets its
own line. The result expression is the last item (no trailing `;`).

The formatter auto-converts `fun f(): T { single }` to `fun f(): T = single`
when the body is a single expression.

**`data`:**
```
data Name[TypeParams] : Sort {
  ctor : type;
  ctor : type;
}
```
Constructors indented +2, each with `name : type;`. The `;` is required
after every constructor including the last one.

**`type` alias:**
```
type alias = typeExpr
```

**`import`:**
```
import "path/to/file.doxa"
import "path/to/file.doxa" { name1, name2 }
import "path/to/file.doxa" as Alias
```
Multiple imports are sorted alphabetically by path, then by alias.

**`typeclass`:**
```
typeclass Name[Param: Constraint] {
  fun method(args): Type;
  val field: Type;
}
```

**`impl`:**
```
impl Name[Type] {
  fun method(args): Type = expr;
  val field: Type = expr;
}
```

**Tactic blocks (`theorem ... := by { ... }`):**
```
theorem name : Statement := by {
  tactic;
  tactic | alt;
}
```

### Expressions

**Application:** juxtaposition on one line when short:
```
f x y z
```
When an application chain exceeds line width, the deepest argument hangs:
```
longFunctionName
  arg1
  arg2
  (complex subExpression)

outerFunction
  (innerFunction a b c)
  lastArg
```
Heuristic: break when an argument starts a new line, indent all
remaining arguments at +2 from the function.

**Lambda:** `(x: A) => body` or `(x) => body` (check-mode).
Multi-parameter: each binder on its own line.

**Pi types:** `(x: A) -> B(x)` (dependent) or `A -> B` (non-dependent).
Multi-binder Pi chains break at `->`:
```
(x: A) ->
(y: B x) ->
C x y
```

**Pattern match:**
```
match scrutinee {
  case pat => body
  case pat =>
    multiLineBody
}
```
Arms at +2. No separator between arms. Short arms on one line.
`returning` motive (when present) on its own line before `{`:
```
match xs returning P {
  case nil => base
  case cons x rest => step
}
```

**Block expressions:**
```
{
  val x: T = e;
  val y: T = f;
  result
}
```
Semicolons inserted after every binding. Result expression last.

**Type application:** `List[A]` or `Vec[A, n]`. No spaces inside brackets.
Comma-separated multiple type args.

### Comments

**Line comments** (`//`): preserved. Placed before the construct they
annotate, at the current indent level. Inline comments after code
are kept on the same line with at least 1 space before `//`.

**Block comments** (`/* */`): preserved. Indentation of block comment
content is normalized.

Comments are a **best-effort** feature in the first implementation.
The tokenizer already captures them; the formatter attaches each
comment to the nearest following construct and re-emits it.

## Architecture

Two approaches exist. **Approach A** is recommended for the first
implementation; Approach B is a refinement for a follow-on.

### Approach A (recommended): AST walker with direct emission

1. Parse the source with `parseProgram` → surface AST
2. Walk the AST depth-first, emitting formatted text to a `StringBuffer`
3. Track current indent level and column position
4. For comments: scan the source text during parsing, extract comments
   and their positions, re-attach to nearest AST node, re-emit during walk
5. Handle line-width decisions by measuring output length

**Pros:** Simple, no CST dependency, works with existing parser.
**Cons:** Comment preservation is heuristic (can misplace comments in
edge cases). No incremental update support.

**Location:** `doxa_tooling/lib/src/format.dart`

### Approach B (future): CST-based with tree splicing

1. Tokenize and build a CST (lossless, preserves all whitespace/comments)
2. Walk the CST, identify whitespace tokens between structural tokens
3. Replace whitespace tokens with normalized ones via `TreeSplicing.replaceAt()`
4. Emit via `GreenNodeOps.toSource()`

**Pros:** Perfect comment preservation, incremental updates possible,
clean separation of formatting from parsing.
**Cons:** More complex, requires understanding the CST node structure
within declarations (which is relatively flat).

## Implementation Steps

### Step 1 — Scaffold: `doxa fmt` CLI command

**File:** `doxa_tooling/bin/doxa.dart`

- Parse `fmt` subcommand with `--check` and `--stdout` flags
- Wire up to a `formatFile()` entry point
- `doxa fmt FILE` — formats in-place
- `doxa fmt --check FILE` — exits 0 if already formatted, 1 if changes needed
- `doxa fmt --stdout FILE` — writes result to stdout

### Step 2 — Formatter core: `doxa_tooling/lib/src/format.dart`

**`Formatter` class** with:
- `String format(String source)` — main entry point
- Internal state: indent level, output buffer, column tracker
- Walk the surface AST from `parseProgram`
- Emit each construct with canonical formatting

**Key methods:**
- `_write(String text)` — append to output, track column
- `_newline()` — emit newline + current indent
- `_indent(int delta)` / `_setIndent(int level)` — manage indent
- `_space()` — emit a space (no-op if at column 0 or after newline)
- `_visit(SExpr expr)` — dispatch on expression kind
- `_visitDecl(SDecl decl)` — dispatch on declaration kind
- `_visitTypeParams(...)` / `_visitValueParams(...)` — parameter formatting
- `_needsWrap(String text, int availableWidth)` — check if wrapping needed

### Step 3 — Declaration formatting (in order)

Implement `_visitDecl` dispatch for each declaration kind:

1. `SValKind` — `val name : type = expr` or `val name = expr`
2. `SImportKind` — `import "path"` variants
3. `STypeAliasKind` — `type name = expr`
4. `SDataKind` — `data name[params] : sort { ctors }`
5. `SDataBlockKind` — mutual `data` declarations
6. `SFunKind` — `fun name[params](args): type = body`
7. `SFunBlockKind` — mutual `fun` declarations
8. `STypeclassKind` — `typeclass` declaration
9. `SImplKind` — `impl` declaration
10. `SQuotKind` — quotient type
11. `SOpenKind` — module open
12. `STacticKind` — `theorem ... := by { tactics }`

### Step 4 — Expression formatting (in order)

Implement `_visit` dispatch for each expression kind:

1. `SIdentKind` — identifier
2. `STypeKind` / `SPropKind` / `SSPropKind` — universe sorts
3. `SAppKind` — application (with line-width wrapping)
4. `SLamKind` — lambda
5. `SPiKind` — Pi type (with `->` breaking)
6. `SMatchKind` — match expression (with case arms)
7. `SBlockKind` — block expression (with semicolon insertion)
8. `SDotKind` — dotted name / record projection
9. `SLetKind` — let binding

### Step 5 — Comment handling

- Extract comments from the source via the tokenizer
- Attach each comment to the nearest following AST node (by span position)
- During emission, emit comments before their associated node
- Inline comments (after a statement on the same line) stay inline

### Step 6 — Import sorting

- Gather all `SImportKind` declarations at the top of the file
- Sort by path (alphabetically)
- Re-emit in sorted order
- If `as` aliases are present, secondary sort by alias name
- Selective imports (`{ names }`) keep their internal order

### Step 7 — `--check` mode

- Format the source
- Compare with original
- If identical: exit 0
- If different: print diff to stderr, exit 1
- Use `dart:convert` for line-by-line comparison or a simple `!=` check

### Step 8 — Tests

**New file:** `doxa_tooling/test/format_test.dart`

Test categories:
1. **Idempotency** — formatting already-formatted output produces the
   same output
2. **Round-trip** — formatting does not change semantics (parsed AST
   before and after formatting are structurally equivalent)
3. **Canonical output** — each construct produces the expected
   formatted string
4. **Semicolon insertion** — missing semicolons in blocks and data
   constructors are added
5. **Import sorting** — imports are alphabetically sorted
6. **Comment preservation** — comments survive formatting at
   approximately the right position
7. **`--check` exit codes** — correct exit codes for formatted vs
   unformatted files
8. **Line-width wrapping** — long lines are broken at appropriate
   points
9. **Existing stdlib files** — all `lib/stdlib/*.doxa` files format
   without error and produce idempotent output

### Step 9 — CI integration

- Add a `doxa fmt --check` step to any CI pipeline
- Ensure all committed `.doxa` files are formatted

## Files Changed

| File | Change | Lines (est.) |
|------|--------|--------------|
| `doxa_tooling/bin/doxa.dart` | `fmt` subcommand + flags | ~40 |
| `doxa_tooling/lib/src/format.dart` | **New file** — formatter core | ~600 |
| `doxa_tooling/test/format_test.dart` | **New file** — formatter tests | ~300 |
| **Total** | | **~940** |

## Risks

1. **Comment placement.** The heuristic of "attach comment to next AST
   node by span position" can misplace comments that appear between
   declarations or at file boundaries. The CST-based approach
   (Approach B) eliminates this risk but is more complex.

2. **Line-width wrapping for application chains.** Pure juxtaposition
   (`f x y z`) makes it hard to decide where to break — there are no
   commas or parens to guide the eye. The heuristic of "break at the
   deepest argument" works for most cases but may produce suboptimal
   results for deeply curried chains.

3. **`fun` body canonicalization.** Auto-converting `{ single }` to
   `= single` changes the AST (the parser distinguishes them). The
   formatted output must still parse and elaborate identically. This
   is straightforward since both forms are semantically equivalent.

4. **Performance.** Formatting the full stdlib should complete in
   under 50ms. The formatter walks the AST once and emits text —
   no complex analysis. Should be fast.

## Exit Criteria

- [ ] `doxa fmt FILE` formats in-place
- [ ] `doxa fmt --check FILE` exits 0 when already formatted, 1 otherwise
- [ ] `doxa fmt --stdout FILE` writes to stdout
- [ ] All `lib/stdlib/*.doxa` files format idempotently
- [ ] All `example/*.doxa` files format idempotently
- [ ] Missing semicolons inserted in blocks and data constructors
- [ ] Imports sorted alphabetically
- [ ] Comments preserved (best-effort)
- [ ] Formatted output parses and elaborates identically to original
- [ ] All 905 existing tests pass
- [ ] `dart analyze` 0 issues
- [ ] `dart format` clean
