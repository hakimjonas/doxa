; Code outline for Doxa: one entry per top-level declaration,
; with the declaration name as the outline label.

(import_declaration
  path: (import_path) @name) @item

(val_declaration
  name: (identifier) @name) @item

(type_alias
  name: (identifier) @name) @item

(fun_declaration
  name: (identifier) @name) @item

(fun_member
  name: (identifier) @name) @item

(theorem_declaration
  name: (identifier) @name) @item

(data_declaration
  name: (identifier) @name) @item

(typeclass_declaration
  name: (identifier) @name) @item

(impl_declaration
  name: (identifier) @name) @item
