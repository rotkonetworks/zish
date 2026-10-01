" Vim syntax file
" Language: jevx — jevx decision scripts (zish feats/jevx)
" Install:  set rtp+=~/rotko/zish/feats/jevx/vim
if exists('b:current_syntax') | finish | endif

syn match   jevxComment   /^\s*".*$/ contains=@Spell
syn match   jevxContinue  /^\s*\\\ze[^|]/
syn match   jevxSet       /^\s*set\>/ nextgroup=jevxOption skipwhite
syn match   jevxOption    /\<\(lines\|probs\|quiet\|text\|invert\|json\|export\|model\|batch\)\>\(=\S*\)\?/ contained nextgroup=jevxOption skipwhite

" KEY SIGIL GATE at the start of a question: team/=billing~.8  urgent?>.7  mood#
syn match   jevxHead      /^\s*[A-Za-z0-9_.-]*[?/#]\S*/ contains=jevxKey,jevxSigil,jevxGate
syn match   jevxKey       /[A-Za-z0-9_.-]\+\ze[?/#]/ contained
syn match   jevxSigil     /[?/#]/ contained nextgroup=jevxGate
syn match   jevxGate      /\(!=\|[<>]=\?\|=\|\~\)\S*/ contained

syn match   jevxAlt       /\\|/ nextgroup=jevxAltName skipwhite
syn match   jevxAltName   /[^:\\]\+\ze:/ contained
syn match   jevxItem      /\\0/
syn match   jevxEscape    /\\[\\n]/
syn match   jevxRef       /`[^`]*`/
" last: a match defined later wins at the same column, and #! starts like a # head
syn match   jevxShebang   /\%1l^#!.*/

hi def link jevxShebang   PreProc
hi def link jevxComment   Comment
hi def link jevxContinue  Special
hi def link jevxSet       Statement
hi def link jevxOption    Type
hi def link jevxKey       Identifier
hi def link jevxSigil     Operator
hi def link jevxGate      Number
hi def link jevxAlt       Delimiter
hi def link jevxAltName   Constant
hi def link jevxItem      Special
hi def link jevxEscape    SpecialChar
hi def link jevxRef       String

let b:current_syntax = 'jevx'
