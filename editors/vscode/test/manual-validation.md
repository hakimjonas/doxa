# VS Code manual validation

## Setup

1. From the repository root, build the local AOT server:

   ```sh
   dart compile exe doxa_tooling/bin/doxa.dart -o doxa_tooling/build/doxa.next
   mv -f doxa_tooling/build/doxa.next doxa_tooling/build/doxa
   ```

2. Open `editors/vscode/test/fixtures/manual-workspace` in VS Code, or run
   `npm run manual:open` from `editors/vscode`.
3. Set `doxa.server.path` to the absolute path of `doxa_tooling/build/doxa`.
4. Run `Developer: Reload Window` and open the `Doxa Language Server` output
   channel. It must contain no startup error.

   The `mv` command requires a Unix-like shell. On another platform, replace
   the existing executable with the platform's file-management command.

## Core behavior

1. In `main.doxa`, hover `Status`, `ready`, and `keep`. The hover type and
   definition target must agree with `dependency.doxa`.
2. Use Go to Definition on `Status`, `ready`, and the imported file path. Each
   command must open the expected source location.
3. In `invalid.doxa`, replace `missing` with `ready`. The diagnostic must clear
   after the edit. Undoing restores the diagnostic at `missing`.
4. In `unicode.doxa`, hover `identity` and `Type`. The result must appear at
   the selected token, not at an earlier column.
5. In `rename.doxa`, use Find References and rename `identity`. Review the
   proposed edit, apply it, then undo it.
6. In `rename_import.doxa`, use Find References and rename `identity`. The
   proposed edit must include its declaration in `rename_base.doxa`, its use in
   `rename_library.doxa`, and its use in `rename_import.doxa`. Apply the edit,
   then undo it.
7. Format `format.doxa`, verify the resulting layout, then undo the edit.
8. Check Outline, folding, completion, signature help, and semantic
   highlighting in `main.doxa` and `dependency.doxa`.

## Imported unsaved text

1. Open `dependency.doxa` and `main.doxa`.
2. Change `Status` to `State` in the open dependency without saving it.
3. `main.doxa` must receive diagnostics for its stale `Status` references.
4. Close `dependency.doxa` without saving. `main.doxa` must return to the
   on-disk `Status` definition and clear those diagnostics.

## Presentation and recovery

1. Confirm that the editor does not request or render Code Lens entries.
2. Confirm that no inlay hint is rendered inside source text.
3. Reload the VS Code window while `main.doxa` and `dependency.doxa` are open.
   Diagnostics, hover, and navigation must recover without reopening files.
4. Record unexpected behavior with the source file, cursor location, expected
   behavior, actual behavior, and the relevant server-output lines.
