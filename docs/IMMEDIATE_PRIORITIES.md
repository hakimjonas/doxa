# Immediate Priorities — Hardening, Modularity, Syntax

> Generated 2026-08-09. Ordered by execution priority.

## Hardening (no reliance on "kernel is small")

| # | Task | Effort | File | Risk addressed |
|---|------|--------|------|----------------|
| 1 | `_drive` loop step-count guard | 15 min | `eval.dart` | Infinite evaluation loops from codomain depth mismatches |
| 2 | `bodyIsNormal` invariant assertion | 15 min | `eval.dart` `_QPiBuildNormal` | Stuck TBound indices from mis-marked closures |
| 3 | Metaprogramming audit + `_validateTerm` at meta-solve time | 1 session | `tactic.dart` | Raw kernel term injection (Lean #14484 analogue) |
| 4 | Stub-to-real verification in `_buildFullEnv` | 15 min | `web_check.dart`, `repl.dart` | Stale `VNeutral(NTop(name))` stubs producing silently-wrong normal forms |

## Modularity

| # | Task | Effort | Description |
|---|------|--------|-------------|
| 5 | Split `eval.dart` (~8k LOC) into 6 domain files | 2-3 sessions | `eval_driver.dart`, `eval_quote.dart`, `eval_conv.dart`, `eval_match.dart`, `eval_infer.dart`, `eval_neutral.dart`. Pure file split, no logic changes. |

## Surface syntax (P0 from ROADMAP.md)

| # | Task | Effort | Description |
|---|------|--------|-------------|
| 6 | Fix annotated `val` check mode | 1 session | Block-level `val x : T = e` uses check mode, not infer mode |
| 7 | Fix `match` return-type substitution | 1 session | Complete scrutinee substitution in nested function calls within branch return types |
