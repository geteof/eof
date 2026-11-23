; Highlights for gitignore, from nvim-treesitter (nvim-treesitter/nvim-treesitter at 52773f0d13a0), Apache-2.0.
; Rewritten by Tools/grammars.py for the predicates Runestone supports.

(comment) @comment @spell

(pattern_char) @string.special.path

[
  (directory_separator)
  (directory_separator_escaped)
] @punctuation.delimiter

[
  (wildcard_char_single)
  (wildcard_chars)
  (wildcard_chars_allow_slash)
] @character.special

[
  (pattern_char_escaped)
  (bracket_char_escaped)
] @string.escape

(negation) @punctuation.special

(bracket_negation) @operator


[
  "["
  "]"
] @punctuation.bracket

(bracket_char) @constant

(bracket_range
  "-" @operator)

(bracket_char_class) @constant.builtin
