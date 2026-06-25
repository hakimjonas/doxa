# P1 3a — Error message improvements

## Problem

Type-mismatch errors dump raw kernel terms with unsolved metas inline:

```
expected ?1 ?a ?b ?c ?d ?e ?f ?g ?h (Eq.rec Bool ((a: Bool) => ...) ...), found Nat
```

The `?f` / `?h` metas appear scattered through enormous expanded `Eq.rec`
chains, making the error unreadable.  The `_prettyValueAt` path calls
`prettyTerm(quote(level, v))` which fully expands every value, including
meta spines that contain the definitions of lemmas whose implicit
arguments couldn't be solved.

## Changes

### 1. Compact term printer (`pretty.dart`)

Add a `prettyTermCompact()` entry point that caps nesting depth.
At depth > 5, render a term as `…` instead of recursing.

### 2. Truncate meta spines (`pretty.dart`)

When rendering `TMeta(id)` applied to arguments (via `TApp`),
truncate the argument list after 1 level of depth for metas.
A bare `?id` stays as-is; `?f hugeTerm1 hugeTerm2` becomes
`?f …`.

### 3. Use compact printer in `report.dart`

Replace `_prettyValueAt` with a depth-limited variant so error
messages never dump multi-kilobyte `Eq.rec` chains.

## Files to modify

| File | Change |
|---|---|
| `doxa/lib/src/pretty.dart` | Add `prettyTermCompact` with depth limit; condense meta spines |
| `doxa/lib/src/report.dart` | Use compact printer in `_prettyValueAt` |
