#!/usr/bin/env bash
#
# Red/green regression harness for zish.
#
# Every case here is a bug that was once real. A case that goes red is a
# regression, not a curiosity — the fix it guards has been undone.
#
#   ./tests/regress.sh              run everything
#   ./tests/regress.sh -v           show expected/actual for passes too
#   ./tests/regress.sh -k subshell  run only cases whose name matches
#
# Exit status is 0 only if every case is green, so this is CI-usable as-is.
#
# Three assertion styles:
#   expect       — exact stdout + exit status. Use when POSIX pins the answer.
#   same_as_bash — differential: zish and bash must agree. Use when writing the
#                  expectation by hand would just be guessing at semantics.
#   no_exec      — a payload is fed to the *interactive* shell and must not
#                  cause a side effect. This is where the TAB-completion RCE
#                  lives; it cannot be tested through `-c` because completion
#                  only runs against a live input stream.

set -uo pipefail

ZISH=${ZISH:-./zig-out/bin/zish}
BASH_BIN=${BASH_BIN:-/bin/bash}

VERBOSE=0
FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        -v) VERBOSE=1; shift ;;
        -k) FILTER="${2:-}"; shift 2 ;;
        *) echo "usage: $0 [-v] [-k pattern]" >&2; exit 2 ;;
    esac
done

if [ ! -x "$ZISH" ]; then
    echo "no zish binary at $ZISH — run 'zig build' first" >&2
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0
FAILED=()

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

selected() {
    [ -z "$FILTER" ] && return 0
    case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac
}

report_pass() {
    PASS=$((PASS + 1))
    green "  PASS"; printf ' %s\n' "$1"
}

report_fail() {
    # $1 name, $2 expected, $3 actual, $4 detail
    FAIL=$((FAIL + 1))
    FAILED+=("$1")
    red "  FAIL"; printf ' %s\n' "$1"
    printf '        %s\n' "$4"
    printf '        expected: %s\n' "$(printf '%s' "$2" | head -c 300 | tr '\n' '|')"
    printf '        actual:   %s\n' "$(printf '%s' "$3" | head -c 300 | tr '\n' '|')"
}

# expect NAME EXPECTED_STDOUT EXPECTED_STATUS SCRIPT
expect() {
    local name="$1" want="$2" want_status="$3" script="$4"
    selected "$name" || { SKIP=$((SKIP + 1)); return; }

    local got status
    got=$(cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" -c "$script" 2>/dev/null)
    status=$?

    if [ "$got" = "$want" ] && [ "$status" = "$want_status" ]; then
        report_pass "$name"
        [ "$VERBOSE" = 1 ] && printf '        %s\n' "$(dim "$script")"
    else
        report_fail "$name" "$want (status $want_status)" "$got (status $status)" "$script"
    fi
}

# same_as_bash NAME SCRIPT
# Differential test. bash is the reference implementation; a mismatch is either
# a zish bug or a deliberate divergence that belongs in `expect` instead.
same_as_bash() {
    local name="$1" script="$2"
    selected "$name" || { SKIP=$((SKIP + 1)); return; }

    if [ ! -x "$BASH_BIN" ]; then SKIP=$((SKIP + 1)); return; fi

    local got want gs ws
    got=$(cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" -c "$script" 2>/dev/null); gs=$?
    want=$(cd "$WORK" && timeout 10 "$BASH_BIN" -c "$script" 2>/dev/null); ws=$?

    if [ "$got" = "$want" ] && [ "$gs" = "$ws" ]; then
        report_pass "$name"
        [ "$VERBOSE" = 1 ] && printf '        %s\n' "$(dim "$script")"
    else
        report_fail "$name" "$want (status $ws)" "$got (status $gs)" "bash differential: $script"
    fi
}

# no_exec NAME KEYSTROKES
# Feeds raw keystrokes to the interactive shell (so completion, ghost text and
# the line editor all run) and asserts the payload did not execute. The payload
# always tries to create $MARKER; if the file appears, something evaluated it.
no_exec() {
    local name="$1" keys="$2"
    selected "$name" || { SKIP=$((SKIP + 1)); return; }

    local marker="$WORK/pwned.$$"
    rm -f "$marker"
    # shellcheck disable=SC2059
    printf "$keys" "$marker" | (cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" >/dev/null 2>&1)

    if [ -e "$marker" ]; then
        rm -f "$marker"
        report_fail "$name" "no side effect" "payload EXECUTED" "code execution: $keys"
    else
        report_pass "$name"
    fi
}

printf '\n%s\n' "$(dim "zish regression suite — $ZISH")"

# ---------------------------------------------------------------------------
printf '\n%s\n' "code execution via completion (TAB, no Enter)"
# ---------------------------------------------------------------------------
# The completion layer probes `<word> --help` to learn a command's flags. It
# used to build that probe as a /bin/sh -c string, so any shell metacharacter
# in the typed word ran as code — on TAB, before the user had run anything.
# Pasting a command to *look* at it was enough.
no_exec "injection: semicolon"        'x;touch$IFS%s -\t'
no_exec "injection: command subst"    'x$(touch %s) -\t'
no_exec "injection: backticks"        'x`touch %s` -\t'
no_exec "injection: pipe"             'x|touch$IFS%s -\t'
no_exec "injection: logical and"      'x&&touch$IFS%s -\t'
no_exec "injection: newline"          'x\ntouch %s\t'
no_exec "injection: via subcommand"   'git b$(touch %s) -\t'
no_exec "injection: via man lookup"   'x;touch$IFS%s --\t'
no_exec "injection: relative path"    './evil -\t'

# ---------------------------------------------------------------------------
printf '\n%s\n' "forked-child body execution"
# ---------------------------------------------------------------------------
# A forked child (pipeline stage, subshell, background job) used to set one
# sticky "exec directly" flag. The first external command in the body then
# replaced the process image, silently discarding every command after it.
expect "subshell runs whole body"      $'one\ntwo\nthree' 0 '( /bin/echo one ; /bin/echo two ; /bin/echo three )'
expect "brace group in pipeline"       $'a\nb'            0 '/bin/echo x | { /bin/echo a ; /bin/echo b ; }'
expect "nested subshell body"          $'X\nY'            0 '( ( /bin/echo X ; /bin/echo Y ) )'
expect "subshell then external"        $'a\nb'            0 '( /bin/echo a ; /bin/echo b )'
same_as_bash "background compound"     '( /bin/echo B1 ; /bin/echo B2 ) & wait'
same_as_bash "pipeline into subshell"  '/bin/echo x | ( /bin/echo a ; /bin/echo b )'

# subshell isolation must survive the fix
expect "subshell cd does not leak"     $'/tmp'   0 'cd /tmp; ( cd / ); pwd'
expect "subshell var does not leak"    $'outer'  0 'v=outer; ( v=inner ); echo $v'
expect "subshell exit status"          $'7'      0 '( exit 7 ); echo $?'

# ---------------------------------------------------------------------------
printf '\n%s\n' "forked-child allocator"
# ---------------------------------------------------------------------------
# The child swapped shell.allocator to page_allocator while the inherited heap
# was full of GPA-owned pointers. The first builtin that freed one — `cd`
# updating PWD — handed a GPA pointer to PageAllocator.free: a panic under
# safety checks, heap corruption without them.
expect "subshell cd (allocator)"       $'/'      0 '( cd / ; pwd )'
expect "subshell export"               $'v'      0 '( export FOO=v ; echo $FOO )'
expect "subshell unset"                $''       0 'x=1; ( unset x ; echo $x )'
expect "background cd"                 $'ok'     0 '( cd / ; /bin/echo ok ) & wait'

# ---------------------------------------------------------------------------
printf '\n%s\n' "redirection"
# ---------------------------------------------------------------------------
# Here strings were written into a pipe while nothing was reading yet, so
# anything past the ~64 KiB pipe buffer blocked the shell forever. They also
# leaked the write end when the write failed. Now materialised to a temp file.
expect "here string small"             $'hello here' 0 'cat <<< "hello here"'
expect "here string past pipe buffer"  $'70001'      0 'x=$(head -c 70000 /dev/zero | tr "\0" "x"); cat <<< "$x" | wc -c'
expect "here string 100k"              $'100001'     0 'x=$(head -c 100000 /dev/zero | tr "\0" "x"); cat <<< "$x" | wc -c'
expect "here string leaves no temp"    $'clean'      0 'cat <<< hi >/dev/null; ls /tmp/zish_herestr_* >/dev/null 2>&1 && echo dirty || echo clean'
same_as_bash "heredoc still works"     'cat <<EOF
line1
line2
EOF'

# ---------------------------------------------------------------------------
printf '\n%s\n' "lexer token buffer"
# ---------------------------------------------------------------------------
# switchToBuf @memcpy'd an already-over-length token into a 1024-byte array.
# A word longer than MAX_TOKEN_LENGTH followed by any backslash escape wrote
# out of bounds. Found by the PRNG sweep in src/fuzz.zig.
LONG=$(printf 'a%.0s' $(seq 1 1100))
expect "long token + escape"           $'ok' 0 "echo ${LONG}\\\\x >/dev/null; echo ok"
expect "long token plain"              $'ok' 0 "echo ${LONG} >/dev/null; echo ok"
expect "long quoted token"             $'ok' 0 "echo \"${LONG}\" >/dev/null; echo ok"
unset LONG

# ---------------------------------------------------------------------------
printf '\n%s\n' "integer overflow in arithmetic"
# ---------------------------------------------------------------------------
# minInt/-1 has no representable quotient; @divTrunc there is illegal
# behaviour. fastParseI64 multiplied without checking, so a 19-digit literal
# overflowed. Both crashed a --release=safe build (what the Makefile ships).
expect "INT_MIN / -1 no crash"         $'0'  0 'x=$(( -9223372036854775807 - 1 )); echo $(( x / -1 ))'
expect "INT_MIN %% -1 no crash"        $'0'  0 'x=$(( -9223372036854775807 - 1 )); echo $(( x % -1 ))'
expect "19-digit compare no crash"     $'no' 0 '[[ 9999999999999999999 -gt 1 ]] && echo yes || echo no'
expect "19-digit test no crash"        $'no' 0 'test 9999999999999999999 -gt 1 && echo yes || echo no'
expect "division by zero errors"       $''   0 'echo $(( 1 / 0 )) >/dev/null 2>&1; true'

# arithmetic that must keep working
same_as_bash "arith precedence"        'echo $(( 2 + 3 * 4 ))'
same_as_bash "arith negative"          'echo $(( -5 + 3 ))'
same_as_bash "arith comparison"        '[ 5 -gt 1 ] && echo yes || echo no'
same_as_bash "arith parens"            'echo $(( (2 + 3) * 4 ))'

# ---------------------------------------------------------------------------
printf '\n%s\n' "core semantics (differential vs bash)"
# ---------------------------------------------------------------------------
same_as_bash "pipeline 3 stages"       '/bin/echo hello | tr a-z A-Z | tr -d O'
same_as_bash "command substitution"    'x=$( /bin/echo sub ); echo got=$x'
same_as_bash "exit status propagates"  'false; echo $?'
same_as_bash "logical and/or"          'true && echo a; false || echo b'
same_as_bash "for loop"                'for i in 1 2 3; do echo $i; done'
same_as_bash "while loop"              'i=0; while [ $i -lt 3 ]; do echo $i; i=$(( i + 1 )); done'
same_as_bash "if elif else"            'if [ 1 -gt 2 ]; then echo a; elif [ 1 -gt 0 ]; then echo b; else echo c; fi'
same_as_bash "case statement"          'case foo in bar) echo no;; foo) echo yes;; esac'
same_as_bash "param expansion default" 'echo ${undefined_var-fallback}'
same_as_bash "param expansion length"  'x=hello; echo ${#x}'
same_as_bash "param substring"         'x=hello; echo ${x:1:3}'
same_as_bash "quoting preserves space" 'echo "a   b"'
same_as_bash "single quotes literal"   'echo '"'"'$notavar'"'"''
same_as_bash "redirect to file"        'echo written > out.txt; cat out.txt'
same_as_bash "append to file"          'echo a > f.txt; echo b >> f.txt; cat f.txt'
same_as_bash "here string"             'cat <<< "here"'
same_as_bash "function definition"     'f() { echo in_func; }; f'
same_as_bash "positional in function"  'f() { echo $1; }; f arg1'
same_as_bash "nested subshell value"   'echo $( echo $( echo deep ) )'

# ---------------------------------------------------------------------------
printf '\n'
# ---------------------------------------------------------------------------
total=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "ALL GREEN"; printf ' — %d passed' "$PASS"
    [ "$SKIP" -gt 0 ] && printf ', %d skipped' "$SKIP"
    printf '\n\n'
    exit 0
else
    red "RED"; printf ' — %d/%d failed\n' "$FAIL" "$total"
    for n in "${FAILED[@]}"; do printf '  %s\n' "$(red "· $n")"; done
    printf '\n'
    exit 1
fi
