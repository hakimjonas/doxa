# Doxa LSP Tooling — Full Improvement Plan

## Architecture Overview

```
doxa (kernel) ─── doxa_tooling (LSP server) ─── doxa-jetbrains (IDE plugin)
     │                      │                          │
     │  check/elab/parse    │  handler/transport/      │  LspServerSupportProvider
     │  ImportResolver      │  web_check/format         │  → spawns "doxa lsp"
     │                      │                          │
     └──────────────────────┴──────────────────────────┘
```

**Current LSP features served:** `initialize`, `didOpen/Change/Close`, `hover`,
`definition`, `completion`, `semanticTokens/full`, `references`, `rename`,
`documentSymbol`, `signatureHelp`, `codeLens`, `formatting`, `shutdown/exit`.

---

## PHASE 1 — Critical Bug Fix (doxa)

**Root cause:** `_processFile` in `doxa/lib/src/import_resolver.dart:245-306`
never calls `importState.importedPaths.add(path)`. When `web_check.dart` later
processes the user's `import` declarations, `_processImport` re-elaborates
already-processed files and throws `DuplicateDeclaration` for every definition
— citing the same source span for both "first" and "second" occurrence.

| #  | Action | File | Details |
|----|--------|------|---------|
| 1.1 | Add `importState.importedPaths.add(path)` | `doxa/lib/src/import_resolver.dart:246` | Before `importState.push(path)`, add the path to `importedPaths` so the idempotent check in `_processImport` at `elab.dart:3847` works. |
| 1.2 | Skip non-aliased `SImportKind` decls | `doxa_tooling/lib/src/web_check.dart:99-125` | Match `bin/doxa.dart:453` pattern — `if (decl.kind is SImportKind) continue;` (except aliased imports which need namespace handling). Their bindings are already in `resolver.bindings`. |

**Verification:** Run `dart run doxa_tooling/bin/doxa.dart check lib/stdlib/proofs.doxa`
and all stdlib files — should produce zero diagnostics except for legitimate
errors.

---

## PHASE 2 — JetBrains CE Compatibility

**Current state:** Plugin depends on `com.intellij.modules.lsp`, which the
JetBrains docs do NOT list among universally available modules (only Ultimate
has it). The target IDE is `IU` in `build.gradle.kts:14`.

**Goal:** Plugin works in any JetBrains IDE (IC, IU, RustRover, CLion, etc.)

**Approach — Hybrid LSP client:**

Rather than depending on an external LSP plugin (LSP4IJ), build a **native
LSP client transport layer** in Kotlin that speaks JSON-RPC 2.0 over stdio.
This gives:
- Full CE compatibility (zero external deps beyond platform modules)
- Full control over server lifecycle, error handling, and feature inspection
- The ability to polyfill features that the IntelliJ LSP API doesn't expose

The plugin will use `com.intellij.modules.platform` +
`com.intellij.modules.lang` (both available in all JB IDEs including CE) and
implement the JSON-RPC framing (`Content-Length: N\r\n\r\n`) directly.

| #  | Action | File | Details |
|----|--------|------|---------|
| 2.1 | Remove `com.intellij.modules.lsp` dependency | `build.gradle.kts` + `plugin.xml` | Replace with `com.intellij.modules.platform` + `com.intellij.modules.lang` |
| 2.2 | Change target IDE to `IC` (Community Edition) | `build.gradle.kts:14` | `create("IC", "2025.1")` — compiles against CE, works in all IDEs |
| 2.3 | Implement JSON-RPC transport | New: `DoxaLspTransport.kt` | Reads JSON-RPC messages from server process stdin/stdout with `Content-Length` framing. Provides `send()` and `onMessage()` API. |
| 2.4 | Implement LSP client connector | New: `DoxaLspConnector.kt` | Manages server process lifecycle (start/stop/restart), message correlation (request ID → response callback), notification dispatch. |
| 2.5 | Implement feature integrations | New files per feature | Wire LSP results into IntelliJ APIs: `ExternalAnnotator` (diagnostics), `DocumentationProvider` (hover), `GotoDeclarationHandler` (definition), `CompletionContributor` (completion), `FindUsagesProvider` (references), `ReferenceInjector` (rename), `StructureViewBuilder` (symbols), `FormattingModelBuilder` (format), `InlayModel` (code lens), `ParameterInfoHandler` (signature help), `SemanticHighlighting` (semantic tokens). |
| 2.6 | Update dependency versions | `build.gradle.kts` + `gradle-wrapper.properties` | Gradle 8.13 → 8.14, Kotlin 2.1.20 → latest, IntelliJ Platform Plugin 2.5.0 → latest |

---

## PHASE 3 — JetBrains Plugin Hardening

| #  | Action | File | Details |
|----|--------|------|---------|
| 3.1 | **Fix binary path resolution** | `DoxaLspConnector.kt` (new) | Use `DoxaSettings.instance.binaryPath.ifEmpty { "doxa" }` instead of hardcoded `"doxa"`. Try settings path first, then PATH, then bundled binary. |
| 3.2 | **Remove bundled binary from repo** | Delete `src/main/resources/bin/doxa` | 8.2MB ELF x86-64 Linux dynamically linked binary — platform-specific, bloats repo, stale. |
| 3.3 | **Add TextMate grammar** | New: `resources/syntaxes/doxa.tmLanguage.json` + `plugin.xml` | Port from VSCode (`vscode/syntaxes/doxa.tmLanguage.json`) — provides syntax highlighting even without LSP server running. |
| 3.4 | **Add commenter** | New + `plugin.xml` | `lang.commenter` for `//` (line) and `/* */` (block) |
| 3.5 | **Add bracket matcher** | New + `plugin.xml` | `lang.braceMatcher` for `()`, `[]`, `{}` |
| 3.6 | **Add structure view** | New + `plugin.xml` | `StructureViewBuilder` powered by LSP `textDocument/documentSymbol` |
| 3.7 | **Add folding builder** | New + `plugin.xml` | `lang.foldingBuilder` powered by LSP `textDocument/foldingRange` |
| 3.8 | **Add color settings page** | New + `plugin.xml` | `colorSettingsPage` for configurable syntax highlighting colors |
| 3.9 | **Add `.gitattributes` for binary detection** | `.gitattributes` | Ensure correct line endings and binary handling |

---

## PHASE 4 — LSP Server Enhancements (doxa)

| #  | Action | File | Details |
|----|--------|------|---------|
| 4.1 | **`$/cancelRequest`** | `handler.dart` + `transport.dart` | Accept `$/cancelRequest` notifications; use a cancellation token in `checkSourceOutput` to abort long-running type checks. The handler stores active request IDs and their cancellation state. |
| 4.2 | **`textDocument/prepareRename`** | `handler.dart` | Return default behavior (the span of the identifier at cursor). Validates rename is possible before user starts editing. |
| 4.3 | **`workspace/didChangeConfiguration`** | `handler.dart` | Accept settings from client (e.g., `doxa.trace.server`, `doxa.maxNumberOfProblems`). |
| 4.4 | **`workspace/didChangeWatchedFiles`** | `handler.dart` | When imported `.doxa` files change on disk, trigger re-check of open documents. |
| 4.5 | **`textDocument/foldingRange`** | `handler.dart` | Return foldable regions: consecutive imports, data type definitions, function bodies, match arms. |
| 4.6 | **`textDocument/documentLink`** | `handler.dart` | Resolve `import "path.doxa"` strings to clickable document links. |
| 4.7 | **`textDocument/semanticTokens/range`** | `handler.dart` | Partial semantic token refresh for visible range only. |
| 4.8 | **Debounce `didChange`** | `handler.dart` | Add 300ms debounce timer — on each edit, reset the timer; only run `checkSourceOutput` when timer fires. Prevents check storm on fast typing. |
| 4.9 | **Completion with snippets** | `handler.dart` | Add `insertTextFormat: 2` (snippet) support for completions with placeholders (e.g., `fun $1($2) : $3 = $0`). |
| 4.10 | **`textDocument/inlayHint`** | `handler.dart` | Show inferred types for bindings that lack annotations, implicit parameter names. |
| 4.11 | **`textDocument/typeDefinition`** | `handler.dart` | Go-to-type-definition (jump from a term to its type/data declaration). |
| 4.12 | **Server version tracking** | `handler.dart:132` | `serverInfo.version` should use actual Doxa version from `pubspec.yaml` instead of hardcoded `"0.1.0"`. |
| 4.13 | **Initialize result: `positionEncoding`** | `handler.dart:101` | Return `"positionEncodings": ["utf-16"]` to be spec-compliant. |

---

## PHASE 5 — Testing, CI/CD, and Polish

| #  | Action | Files | Details |
|----|--------|-------|---------|
| 5.1 | **LSP integration tests** (doxa) | New: `doxa_tooling/test/lsp_test.dart` | Spawn `doxa lsp` as subprocess, send JSON-RPC messages, assert responses. Test: initialize, didOpen, hover, definition, completion, semanticTokens, references, rename, formatting, diagnostics, shutdown. |
| 5.2 | **Plugin unit tests** (doxa-jetbrains) | New: `src/test/kotlin/` | Test: DoxaLspTransport message framing, DoxaLspConnector startup/shutdown, DoxaSettings persistence, DoxaConfigurable UI state. |
| 5.3 | **GitHub Actions CI** (doxa-jetbrains) | New: `.github/workflows/ci.yml` | Build plugin with `./gradlew buildPlugin`, run tests, verify with Plugin Verifier. |
| 5.4 | **GitHub Actions CI** (doxa) | New or existing `.github/workflows/` | Already has `.github/` — verify it has CI. If not, add: `dart analyze` (both packages), `dart format --set-exit-if-changed`, `dart test` (both packages), stdlib checks. |
| 5.5 | **Run full pre-commit checklist** | — | All 6 steps from `AGENTS.md` must pass after all doxa changes. |
| 5.6 | **Documentation** | `contrib/jetbrains/README.md` + plugin README | Update with CE compatibility info, installation instructions, settings guide. |
| 5.7 | **`.gitignore` for bundled binary** | `doxa-jetbrains/.gitignore` | Ensure `src/main/resources/bin/doxa` is untracked (if not deleted outright). |

---

## Binary Strategy

Rather than bundling platform-specific binaries:

1. **User installs doxa via `dart pub global activate doxa_tooling`** — this
   compiles a native binary on their platform and puts it on PATH.
2. **Plugin finds `doxa` on PATH** (default) or uses the configured path from
   settings.
3. **If neither works**, the plugin shows a notification: "Doxa binary not
   found. Install with: `dart pub global activate doxa_tooling`"
4. **CI-published binaries**: Optionally, the GitHub CI can produce `doxa` AOT
   binaries for `linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
   `windows-x64` as release artifacts — but not bundled in the plugin repo.

---

## Risk Items

| Risk | Mitigation |
|------|------------|
| Phase 2 manual LSP client is large effort (~20+ Kotlin files) | Implement incrementally, starting with transport + diagnostics + hover + completion; rest follow as features are wired |
| Phase 2 is sensitive to IntelliJ API changes | Use stable extension points (`ExternalAnnotator`, `DocumentationProvider`, etc.) which have been stable for many versions |
| `$/cancelRequest` requires threading in Dart | Use `Isolate` or async `Future` with a flag; don't over-engineer — set a volatile bool on cancel and check between declaration processing |
| Multiple `.doxa` files in a workspace may require `workspace/didChangeWatchedFiles` before Phase 4 is done | Accept that import changes require a server restart initially; Phase 4.4 addresses this |

---

## Estimated File Count

| Phase | Files Changed | Files Created | Files Deleted |
|-------|---------------|---------------|---------------|
| Phase 1 | 2 | 0 | 0 |
| Phase 2 | 3 | 15-20 | 0 |
| Phase 3 | 1 | 4-5 | 1 |
| Phase 4 | 2 | 0 | 0 |
| Phase 5 | 0 | 4-6 | 0 |
| **Total** | **8** | **23-31** | **1** |

---

## Success Criteria

1. `dart run doxa_tooling/bin/doxa.dart check lib/stdlib/proofs.doxa` produces
   **zero false-positive duplicate declaration errors**
2. JetBrains plugin loads in **Community Edition** 2025.1+ and shows
   diagnostics + hover + completion for `.doxa` files
3. All 13 LSP features from the current `initialize` response work end-to-end
   in CE
4. Binary path from settings page is honored
5. `.doxa` files have syntax highlighting via TextMate grammar (without LSP
   server)
6. `//` and `/* */` commenting, `()[]{}` bracket matching work
7. Full pre-commit checklist from `AGENTS.md` passes
8. `./gradlew buildPlugin` produces a working plugin artifact
9. Zero regressions in existing kernel and tooling tests
