#!/bin/bash
# Regression harness: run every case through zish and bash, diff the output.
# Any mismatch is printed as FAIL. Usage: regress.sh /path/to/zish
Z="${1:-/steam/rotko/zish/zig-out/bin/zish}"
pass=0; fail=0
t(){
  local desc="$1"; shift
  local script="$1"
  local zo bo
  zo="$("$Z" -c "$script" 2>&1)"; zr=$?
  bo="$(bash -c "$script" 2>&1)"; br=$?
  if [ "$zo" = "$bo" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL: %s\n   script: %s\n   zish:[%s] (rc=%d)\n   bash:[%s] (rc=%d)\n' \
      "$desc" "$script" "$(printf '%s' "$zo"|tr '\n' '^')" "$zr" "$(printf '%s' "$bo"|tr '\n' '^')" "$br"
  fi
}

# --- positional / special params ---
t 'func $#'          'f(){ echo $#; }; f a b c'
t 'func "$@" iter'   'f(){ for a in "$@"; do printf "<%s>" "$a"; done; echo; }; f "a b" c'
t 'func "$*"'        'f(){ echo "$*"; }; f a b c'
t 'func arg valid'   'f(){ [ $# -lt 2 ] && echo need2 || echo ok; }; f one'
t 'save/restore pos' 'set -- p q; f(){ echo -n "in=$# "; }; f a; echo "after=$#"'
t 'nested pos'       'f(){ echo -n "n=$# "; }; g(){ f X Y; echo "g=$#"; }; g A B C'
t 'shift in func'    'f(){ shift; echo $1; }; f a b c'
t '"$@" forward'     'g(){ printf "(%s)" "$@"; echo; }; f(){ g "$@"; }; f "p q" r'

# --- word splitting ---
t 'unquoted split'   'files="a b c"; for f in $files; do echo "<$f>"; done'
t 'set -- $x'        'x="1 2 3"; set -- $x; echo $#'
t 'quoted no split'  'x="a b c"; echo "$x"'
t 'multi-space'      'v="  a   b  "; for w in $v; do echo "[$w]"; done'
t 'empty var arg'    'e=""; echo before $e after'
t 'cat $path'        'p="/etc/hostname"; cat $p'

# --- local scoping ---
t 'local shadow'     'x=g; f(){ local x=i; echo $x; }; f; echo $x'
t 'local no leak'    'f(){ local y=42; }; f; echo "[$y]"'
t 'local dynamic'    'x=1; f(){ local x=2; g; echo $x; }; g(){ x=3; }; f; echo $x'
t 'local multi'      'f(){ local a=1 b=2; echo "$a $b"; }; f; echo "[$a][$b]"'

# --- test builtin ---
t 'test quoted'      'x=ok; [ "$x" = ok ] && echo Y || echo N'
t 'test -o'          '[ a = b -o c = c ] && echo Y || echo N'
t 'test -a'          '[ a = a -a b = c ] && echo Y || echo N'
t 'test -o int'      '[ 1 -eq 2 -o 3 -eq 3 ] && echo Y || echo N'
t 'test negate'      '[ ! a = a ] && echo Y || echo N'
t 'test -n -z'       '[ -n "" -o -z "" ] && echo Y || echo N'

# --- param expansion ---
t 'strip suffix var' 'f=foo.txt; E=.txt; echo "${f%$E}"'
t 'strip prefix var' 'f=path/x; P=path/; echo "${f#$P}"'
t 'strip glob'       'f=a.b.c; echo "${f%.*} ${f%%.*}"'
t 'substr'           'x=hello; echo "${x:1:3}"'
t 'default val'      'echo "${undef:-fallback}"'
t 'alt val'          'x=set; echo "${x:+yes}"'

# --- braces / grouping ---
t 'bare {}'          'echo {}'
t 'find {}'          'echo a{}b'
t 'brace list'       'echo {a,b,c}'
t 'brace range'      'echo {1..3}'
t 'group'            '{ echo grouped; }'

# --- heredocs ---
t 'single heredoc'   'cat <<EOF
hello
EOF'
t 'chained heredoc'  'cat <<A
one
A
cat <<B
two
B'
t 'quoted heredoc'   'cat <<'"'"'Q'"'"'
no$x
Q'

# --- core behaviors ---
t 'pipe'             'echo hello | tr a-z A-Z'
t 'and-or'           'true && echo yes || echo no'
t 'subshell'        '(echo a; echo b)'
t 'cmd subst'        'echo "[$(echo hi)]"'
t 'arith'            'echo $((2 + 3 * 4))'
t 'var assign'       'x=5; y=$x; echo $y'
t 'exit code'        'false; echo $?'
t 'while loop'       'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done'
t 'case'             'x=b; case $x in a) echo A;; b) echo B;; esac'
t 'if elif'          'x=2; if [ $x = 1 ]; then echo one; elif [ $x = 2 ]; then echo two; fi'
t 'nested quote'     'echo "a '"'"'b'"'"' c"'
t 'glob'             'cd /etc && echo hostname* | grep -q hostname && echo globok'

# --- param slicing / indirection ---
t 'slice @:2'        'set -- a b c d; echo "${@:2}"'
t 'slice @:2:2'      'set -- a b c d; echo "${@:2:2}"'
t 'slice *:3'        'set -- a b c d; echo "${*:3}"'
t 'indirect'         'v=hi; r=v; echo "${!r}"'
t 'indirect nested'  'x=1; a=x; b=a; echo "${!b}"'

# --- printf ---
t 'printf %b'        'printf "%b\n" "a\tb"'
t 'printf %b hex'    'printf "%b\n" "x\x41y"'
t 'printf %q space'  'printf "%q\n" "a b"'
t 'printf %q plain'  'printf "%q\n" simple'
t 'printf %q empty'  'printf "%q\n" ""'

# --- PIPESTATUS ---
t 'pipestatus 01'    'false | true; echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}"'
t 'pipestatus all'   'false | false | true; echo "${PIPESTATUS[@]}"'
t 'pipestatus codes' 'sh -c "exit 3" | sh -c "exit 7"; echo "${PIPESTATUS[0]} ${PIPESTATUS[1]}"'

# --- trap EXIT ---
t 'trap exit'        'trap "echo bye" EXIT; echo hi'
t 'trap exit multi'  'trap "echo A; echo B" EXIT; echo main'

# --- IFS ---
t 'ifs colon for'    'IFS=:; x="a:b:c"; for w in $x; do echo "<$w>"; done'
t 'ifs colon set'    'IFS=:; p="/u/b:/b"; set -- $p; echo "$# [$1] [$2]"'
t 'ifs echo'         'IFS=:; a="x:y"; echo $a'
t 'ifs default'      'x="a b c"; for w in $x; do echo "<$w>"; done'

# --- echo empty fields ---
t 'echo empty var'   'e=""; echo before $e after'
t 'echo quoted empty' 'echo a "" b'

# --- pipeline exec correctness (the argv[0] fix) ---
t 'pipe script true' 'true | printf "%s\n" ran'
t 'pipe cd ls grep'  'cd /etc && ls | grep -c hostname'
t 'pipe group'       '{ echo x; } | cat'

# --- arithmetic command & C-style for ---
t 'arith cmd true'   '(( 1 + 1 )); echo $?'
t 'arith cmd false'  '(( 0 )); echo $?'
t 'arith cmd cond'   '(( 5 > 3 )) && echo yes'
t 'arith cmd incr'   'x=5; (( x++ )); echo $x'
t 'cfor basic'       'for ((i=0;i<3;i++)); do echo $i; done'
t 'cfor sum'         'sum=0; for ((i=1;i<=10;i++)); do sum=$((sum+i)); done; echo $sum'
t 'cfor break'       'for ((i=0;i<9;i++)); do [ $i -eq 3 ] && break; echo $i; done'
t 'cfor continue'    'for ((i=0;i<5;i++)); do [ $i -eq 2 ] && continue; echo $i; done'
t 'cfor nested'      'for ((i=0;i<2;i++)); do for ((j=0;j<2;j++)); do echo "$i$j"; done; done'
t 'cfor infinite'    'for ((;;)); do echo once; break; done'

# --- array literals ---
t 'arr literal'      'a=(1 2 3); echo "${#a[@]}":"${a[@]}"'
t 'arr quoted space' 'a=("a b" c); echo "${#a[@]}":"${a[0]}"'
t 'arr sq space'     "a=('a b' c); echo \"\${#a[@]}\":\"\${a[0]}\""
t 'arr quoted var'   'a=("$HOME"); echo "${#a[@]}":"${a[@]}"'
t 'arr unq var split' 'x="foo bar"; a=($x); echo "${#a[@]}":"${a[@]}"'
t 'arr cmdsubst'     'a=($(echo one two)); echo "${#a[@]}":"${a[@]}"'
t 'arr quoted cmdsub' 'a=("$(echo p q)"); echo "${#a[@]}":"${a[0]}"'
t 'arr mixed elems'  'a=("x y" "$(echo p q)" z); echo "${#a[@]}":"${a[@]}"'
t 'arr append unq'   'a=(a b c); x=z; a+=($x); echo "${#a[@]}"'
t 'arr append lit'   'a=(a b); a+=(c d); echo "${#a[@]}":"${a[@]}"'
t 'arr arith elems'  'a=($((1+2)) $((3*3))); echo "${a[@]}"'
t 'arr nested paren' 'a=("nested (paren) ok" x); echo "${#a[@]}":"${a[0]}"'
t 'arr sq literal $' "a=('lit \$x' b); echo \"\${#a[@]}\":\"\${a[0]}\""
t 'arr adjacent q'   'a=("a"b c); echo "${#a[@]}":"${a[0]}"'
t 'arr backtick'     'a=(`echo hi there`); echo "${#a[@]}":"${a[@]}"'
t 'arr empty'        'a=(); echo "${#a[@]}"'
t 'arr prepost sub'  'a=(pre$(echo m n)post); echo "${#a[@]}":"${a[@]}"'

# --- heredoc body expansion timing ---
t 'hd assign then'   $'x=EXP; cat <<C\nhas $x\nC'
t 'hd existing var'  $'cat <<C\nhome=$HOME done\nC'
t 'hd quoted delim'  $'cat <<\'C\'\nno $HOME here\nC'
t 'hd dash strip'    $'x=1; cat <<-C\n\tval $x\n\tC'
t 'hd chained'       $'a=A; cat <<X\n$a\nX\nb=B; cat <<Y\n$b\nY'
t 'hd arith'         $'x=5; cat <<C\n$((x+1))\nC'
t 'hd cmdsubst'      $'cat <<C\n$(echo sub)\nC'
t 'hd loop reexpand' $'for x in a b c; do cat <<E\nitem $x\nE\ndone'
t 'hd prior cmd'     $'printf "%s\\n" pre; cat <<C\nmid tag\nC'

# --- mapfile / readarray ---
ti 'mapfile basic'   'a\nb\nc\n'    'mapfile -t arr; echo "${#arr[@]} [${arr[1]}]"'
ti 'mapfile no-nl'   'a\nb\nc'      'mapfile -t arr; echo "${#arr[@]}:${arr[*]}"'
ti 'mapfile keepnl'  'a\nb\n'       'mapfile arr; echo "${#arr[@]}:${arr[0]}${arr[1]}"'
ti 'mapfile -n2'     'a\nb\nc\nd\n' 'mapfile -t -n 2 arr; echo "${#arr[@]}:${arr[*]}"'
ti 'mapfile -s1'     'a\nb\nc\nd\n' 'mapfile -t -s 1 arr; echo "${#arr[@]}:${arr[*]}"'
ti 'mapfile default' 'p\nq\n'       'mapfile -t; echo "${MAPFILE[*]}"'
ti 'readarray'       'a\nb\n'       'readarray -t arr; echo "${#arr[@]}"'
ti 'mapfile empty'   ''            'mapfile -t arr; echo "${#arr[@]}"'
ti 'mapfile -O0'     'x\ny\n'       'mapfile -t -O 0 arr; echo "${arr[*]}"'

echo "-------------------------------------------"
echo "PASS=$pass FAIL=$fail"
