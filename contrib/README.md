# Editor configuration for Doxa

Editors with an LSP client can connect to `doxa lsp`. The server provides
diagnostics, hover, definition, completion, references, rename, document
symbols, signature help, formatting, folding ranges, and semantic tokens.

## Neovim (native LSP, nvim-lspconfig)

```lua
require('lspconfig').doxa = {
  default_config = {
    cmd = { 'doxa', 'lsp' },
    filetypes = { 'doxa' },
    root_dir = require('lspconfig.util').root_pattern('.git'),
    settings = {},
  },
}
require('lspconfig').doxa.setup{}
```

For syntax highlighting, add to `~/.config/nvim/syntax/doxa.vim`:

```vim
if exists("b:current_syntax")
  finish
endif

syntax keyword doxaKeyword val fun data type match case returning import and by opaque rec struct termination_by where as typeclass impl theorem with
syntax keyword doxaType Type Prop SProp
syntax match doxaNumber "\<[0-9]\+\>"
syntax region doxaString start=+"+ skip=+\\"+ end=+"+
syntax match doxaComment "//.*$"
syntax region doxaComment start="/\*" end="\*/"

highlight default link doxaKeyword Keyword
highlight default link doxaType Type
highlight default link doxaNumber Number
highlight default link doxaString String
highlight default link doxaComment Comment

let b:current_syntax = "doxa"
```

## Vim (coc.nvim)

Add this JSON to Coc's `coc-settings.json`. Open it with `:CocConfig`.

```json
{
  "languageserver": {
    "doxa": {
      "command": "doxa",
      "args": ["lsp"],
      "filetypes": ["doxa"],
      "rootPatterns": [".git"]
    }
  }
}
```

## JetBrains

The Doxa JetBrains plugin is in the main repository at
[`editors/jetbrains/`](../editors/jetbrains/). It targets IntelliJ Platform
2025.1-compatible IDEs. Build it with `./gradlew buildPlugin` using JDK 21 or
later, then install
`build/distributions/doxa-jetbrains.zip`.

See [`contrib/jetbrains/README.md`](jetbrains/README.md) for setup and
configuration.

## Emacs (eglot)

```elisp
(add-to-list 'eglot-server-programs '(doxa-mode . ("doxa" "lsp")))
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `(doxa-mode . ("doxa" "lsp"))))
```

Minimal major mode for `doxa-mode`:

```elisp
(define-derived-mode doxa-mode prog-mode "Doxa"
  "Major mode for Doxa proof assistant files."
  (setq font-lock-defaults '(doxa-font-lock-keywords)))

(setq doxa-font-lock-keywords
      `((,(regexp-opt '("val" "fun" "data" "type" "match" "case"
                        "returning" "import" "and" "by" "opaque"
                        "rec" "struct" "termination_by" "where"
                        "as" "typeclass" "impl" "theorem" "with")
                      'words)
         . font-lock-keyword-face)
        (,(regexp-opt '("Type" "Prop" "SProp") 'words)
         . font-lock-type-face)
        ("\"[^\"]*\""
         . font-lock-string-face)
        ("//.*$"
         . font-lock-comment-face)))
```

## Emacs (lsp-mode)

```elisp
(require 'lsp-mode)
(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection '("doxa" "lsp"))
  :major-modes '(doxa-mode)
  :server-id 'doxa-lsp))
(add-to-list 'auto-mode-alist '("\\.doxa\\'" . doxa-mode))
```
