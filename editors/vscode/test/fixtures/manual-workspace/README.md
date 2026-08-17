# Doxa VS Code manual-test workspace

Open this directory as a VS Code workspace after building the local AOT server
from `doxa_tooling/`. The files exercise the standard LSP paths without
modifying the standard library.

`dependency.doxa` and `main.doxa` are a valid imported pair. Edit the open,
unsaved dependency to test dependent diagnostics, completion, and navigation.
Close it without saving to confirm that the dependent returns to the on-disk
definition.

`invalid.doxa` contains one unresolved identifier. Replace `missing` with
`ready` to verify diagnostic repair, then undo the edit.

`unicode.doxa` tests positions after a non-BMP character. `format.doxa` is
intentionally compact. `rename.doxa` contains a top-level declaration and use
for Find References and Rename.

`rename_base.doxa`, `rename_library.doxa`, and `rename_import.doxa` form a
transitive import chain for cross-file Find References and Rename. Rename
`identity` from `rename_import.doxa` and verify that the edit affects all
three files.
