# Immediate Priorities — Hardening, Modularity, Syntax

> Generated 2026-08-09. Updated 2026-08-09 after implementation.

## Hardening (Done)

| # | Task | Status | Commits |
|---|------|--------|---------|
| 1 | `_drive` loop step-count guard | Done | `f679574` |
| 2 | `bodyIsNormal` invariant assertion + `_maxTBoundIndex` | Done | `f679574` |
| 3 | Metaprogramming `_validateTerm` at meta-solve time | Done | `4d3efef` |
| 4 | `_buildFullEnv` stub verification | Done | `4d3efef` |

## Modularity (First pass done)

| # | Task | Status |
|---|------|--------|
| 5 | Extract `eval_helpers.dart` (152 lines: first-order match helpers, `_maxTBoundIndex`) via `part` mechanism | Done (`baacf59`) |
| 5a | Further eval.dart splits (unification block, match refinement, level helpers) | Deferred — extract incrementally alongside feature work |

## Surface syntax (Already done — from remote branch)

| # | Task | Status | Source |
|---|------|--------|--------|
| 6 | Annotated `val` check mode | Done | `d5e30fe` (P0 Fix 2) — `elab.dart:3314` for top-level, `elab.dart:1874` for block-level |
| 7 | Match return-type substitution | Done | `d5e30fe` (P0 Fix 1) — `substNVar` walks VFun spines |
