" .jevx — jevx decision scripts (feats/jevx)
autocmd BufNewFile,BufRead *.jevx setfiletype jevx
autocmd BufNewFile,BufRead * if getline(1) =~# '^#!.*\<jevx\>' | setfiletype jevx | endif
