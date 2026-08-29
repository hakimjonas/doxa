; Syntax highlighting for Doxa.
;
; Captures follow the tree-sitter standard naming used by Zed,
; Neovim, and Helix themes.

; Comments

(line_comment) @comment
(block_comment) @comment

; Declarations

[
  "val"
  "rec"
  "fun"
  "data"
  "type"
  "theorem"
  "typeclass"
  "impl"
  "import"
  "as"
  "and"
  "opaque"
  "struct"
  "termination_by"
  "returning"
] @keyword

; Match and tactic blocks

[
  "match"
  "case"
  "by"
] @keyword

; Tactics are keyword-led steps inside by blocks.

(tactic
  [
    "intro"
    "exact"
    "apply"
    "refl"
    "rewrite"
    "induction"
    "trivial"
  ]) @keyword

; Sorts and universes

(sort) @type.builtin

; Imports

(import_path) @string.special

(import_items
  (identifier) @constant)

(import_declaration
  alias: (identifier) @variable)

; Declaration names

(fun_declaration
  name: (identifier) @function)

(fun_member
  name: (identifier) @function)

(class_method
  name: (identifier) @function.method)

(impl_method
  name: (identifier) @function.method)

(val_declaration
  name: (identifier) @variable)

(type_alias
  name: (identifier) @type)

(data_declaration
  name: (identifier) @type)

(typeclass_declaration
  name: (identifier) @type)

(impl_declaration
  name: (identifier) @type)

(theorem_declaration
  name: (identifier) @function)

(local_val
  name: (identifier) @variable)

; Constructors in patterns and data bodies

(constructor
  name: (identifier) @constructor)

(match_arm
  (identifier) @constructor)

; Binders

(value_binder
  name: (identifier) @variable.parameter)

(type_binder
  name: (identifier) @variable.parameter)

(parameter
  name: (identifier) @variable.parameter)

; Numbers

(number) @number

; Operators and punctuation

[
  "=>"
  "->"
  "="
  ":"
  "&"
  "|"
  ","
  ";"
  "."
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket
