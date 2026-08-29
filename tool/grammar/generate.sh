#!/usr/bin/env sh
# Regenerates the tree-sitter-doxa grammar from the IR in this directory.
#
# Flow (see PLAN-doxa-phase-t.md T2/T3): edit doxa.ir.json here, run this
# script, and commit both repositories together, referencing each other's
# commit in the messages.
#
# Environment:
#   RUMIL_GRAMMARS    path to the rumil_grammars package
#                     (default: ~/google/rumil-dart/rumil_grammars)
#   TREE_SITTER_DOXA  path to the tree-sitter-doxa repository
#                     (default: ~/examples/tree-sitter-doxa)
set -eu

RUMIL_GRAMMARS="${RUMIL_GRAMMARS:-$HOME/google/rumil-dart/rumil_grammars}"
TREE_SITTER_DOXA="${TREE_SITTER_DOXA:-$HOME/examples/tree-sitter-doxa}"

here="$(cd "$(dirname "$0")" && pwd)"
ir="$here/doxa.ir.json"

test -d "$RUMIL_GRAMMARS" || {
  echo "generate.sh: rumil_grammars not found at $RUMIL_GRAMMARS" >&2
  echo 'generate.sh: set RUMIL_GRAMMARS to the package checkout' >&2
  exit 1
}
test -d "$TREE_SITTER_DOXA" || {
  echo "generate.sh: tree-sitter-doxa not found at $TREE_SITTER_DOXA" >&2
  echo 'generate.sh: set TREE_SITTER_DOXA to the repository checkout' >&2
  exit 1
}

# Emit src/grammar.json from the IR (validated inside the generator).
(cd "$RUMIL_GRAMMARS" && dart run bin/rumil_grammars.dart \
  --input "$ir" --out "$TREE_SITTER_DOXA/src")

# Regenerate the parser and run the corpus tests. The grammar path is
# passed explicitly: the repository has no root grammar.js, the JSON
# emitted above is the source of truth.
cd "$TREE_SITTER_DOXA"
tree-sitter generate src/grammar.json
tree-sitter test

# Sync the query files into the Zed extension (same files, copied; the
# extension consumes its own copies).
zed_ext="$(dirname "$TREE_SITTER_DOXA")/doxa/editors/zed/languages/doxa"
if [ -d "$zed_ext" ]; then
  cp queries/highlights.scm queries/brackets.scm queries/indents.scm \
    queries/outline.scm "$zed_ext/"
fi

echo "generate.sh: grammar.json and parser regenerated; corpus tests passed."
