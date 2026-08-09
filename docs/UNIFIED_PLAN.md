# Unified Implementation Plan — Doxa Proof Assistant

> Generated 2026-08-09. Kernel/Proof work and Tooling work interleaved.

## 1. Error message quality ✅

**Done (`faa9f88`):** Unsolved metas rendered as `_` instead of `?id`.
Further improvements: surface-level rendering of diff paths, better
error messages for unsolved implicit arguments.

**Status:** First pass done. Room for more refinement.

## 2. Recursive `val`/`fun` — Already done

`val rec` and `fun ... and ...` mutual recursion are both implemented
(`parse.dart:265`, `elab.dart:1799`, `surface.dart:247`).  `TLet(isRec: true)`
is the kernel construct.  The ROADMAP target `even_implies_double` is in
`case_study.doxa` and type-checks.

**Status:** Done (from remote branch). Striking from active plan.

## 2b. Proof state in LSP

**Tooling:** Custom LSP notification `$/doxa/proofState` — after each
`:step` in interactive proof mode, push current goal type, context
binders, and open subgoal count to the editor.  Enables inline
proof-state display in VS Code.

**Files:** `doxa_tooling/lib/src/lsp/handler.dart`,
`doxa_tooling/lib/src/repl.dart`

**Session estimate:** 1

## 3. Stdlib: gcd + primes + playground

**Stdlib:** Add `gcd`, `div`, `prime` predicates to the standard library.
Prove basic number theory lemmas.  Unlocks "infinite primes" as a second
case study alongside sqrt2.

**Tooling:** Upgrade `web/index.html` playground to consume structured
`CheckSuccess` JSON — per-declaration types and normal forms displayed in
an expandable list.  Syntax highlighting via LSP semantic tokens.

**Files:** `lib/stdlib/Nat/nat.doxa` (or new file), `doxa_tooling/web/index.html`

**Session estimate:** 2-3

## 4. Formatter LSP integration

**Tooling:** Register `textDocument/formatting` capability in LSP initialize.
Handler delegates to `formatSource()` from the existing formatter library.
Returns `TextEdit[]` replacing the whole document.

**Files:** `doxa_tooling/lib/src/lsp/handler.dart`,
`doxa_tooling/lib/src/lsp/protocol.dart`

**Session estimate:** 0.5

## 5. Completion ranking + tutorial

**Tooling:** Completion items sorted by frequency — names used more often
appear first.  Simple counter per LSP session, reset on `didOpen`.

**Docs:** Update `docs/tutorial.md` with interactive proof mode section.
Reference the proof guide.  Update installation instructions for `doxa lsp`
and the VS Code extension.

**Files:** `doxa_tooling/lib/src/lsp/handler.dart`, `docs/tutorial.md`

**Session estimate:** 1

## Session totals

| # | Item | Sessions |
|---|------|----------|
| 1 | Error message quality | 1-2 |
| 2 | Recursive val/fun + proof state LSP | 1-2 |
| 3 | Stdlib: gcd + primes + playground | 2-3 |
| 4 | Formatter LSP integration | 0.5 |
| 5 | Completion ranking + tutorial | 1 |
| **Total** | | **5.5-8.5** |
