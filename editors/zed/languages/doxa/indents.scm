; Indentation for Doxa.
;
; Indent inside brace-delimited bodies (data, typeclass, impl, match,
; by blocks, block expressions) and parenthesized or bracketed
; expressions; dedent at the closing delimiter.

[
  (data_declaration)
  (typeclass_declaration)
  (impl_declaration)
  (match_expression)
  (by_block)
  (block_expr)
] @indent

(parenthesized_expression ")" @end)
(bracket_arguments "]" @end)
(data_declaration "}" @end)
(typeclass_declaration "}" @end)
(impl_declaration "}" @end)
(match_expression "}" @end)
(by_block "}" @end)
(block_expr "}" @end)
