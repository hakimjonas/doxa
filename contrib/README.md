# Editor Configuration for Doxa

All editors with a generic LSP client can connect to `doxa lsp` for
diagnostics, hover, go-to-definition, and completion. The snippets
below configure the most common editors.

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

Add to `~/.config/nvim/coc-settings.json` or `vimrc`:

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

## JetBrains (IntelliJ, CLion, etc.)

1. Install the **LSP4IJ** plugin (File → Settings → Plugins → Marketplace)
2. Go to File → Settings → Languages & Frameworks → Language Servers
3. Add a new server:
   - Name: `doxa`
   - Type: `Custom`
   - Command: `doxa lsp`
   - Associated file types: `*.doxa`
4. Apply the settings. The LSP will start automatically when you open a `.doxa` file.

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
