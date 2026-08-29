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
printf '\n%s\n' "capability restriction (--profile)"
# ---------------------------------------------------------------------------
# The shell is the fork/exec chokepoint, so it is the only place that can bound
# what a command touches without trusting the command. Landlock is inherited
# across exec and cannot be relaxed, so restricting the session restricts every
# child — that inheritance is the property worth guarding.
#
# Skipped where the kernel has no Landlock (it is queried, not assumed).
if "$ZISH" --profile readonly -c 'true' 2>/dev/null; then
    # These must run *with* the flag, so they cannot use expect() (which shells
    # out without it). An earlier version of this block did, and passed by
    # testing unrestricted behaviour.
    rm -f /tmp/zish_sbx_probe
    if "$ZISH" --profile readonly -c 'echo x > /tmp/zish_sbx_probe' >/dev/null 2>&1 && [ -e /tmp/zish_sbx_probe ]; then
        rm -f /tmp/zish_sbx_probe
        report_fail "readonly blocks writes" "write refused" "write succeeded" "sandbox not enforced"
    else
        report_pass "readonly blocks writes"
    fi
    if "$ZISH" --profile readonly -c 'cat /etc/hostname >/dev/null' >/dev/null 2>&1; then
        report_pass "readonly still allows reads"
    else
        report_fail "readonly still allows reads" "read allowed" "read refused" "over-restricted"
    fi
    # A child process must not be able to escape the restriction.
    if "$ZISH" --profile readonly -c '/bin/sh -c "echo x > /tmp/zish_sbx_child" 2>/dev/null' 2>/dev/null; then :; fi
    if [ -e /tmp/zish_sbx_child ]; then
        rm -f /tmp/zish_sbx_child
        report_fail "restriction inherited by children" "child blocked" "child wrote the file" "sandbox escape"
    else
        report_pass "restriction inherited by children"
    fi
    rm -f /tmp/zish_sbx_probe

    # The "pledge" half: a restrictive profile also installs a seccomp filter
    # (mode 2 in /proc/self/status), inherited across exec, that denies ptrace
    # and friends — the tested escape #3. `none` and no-profile leave it off.
    if [ "$(cat /proc/self/status 2>/dev/null | grep -c '^Seccomp')" != "0" ]; then
        m=$("$ZISH" --profile readonly -c 'grep ^Seccomp: /proc/self/status' 2>/dev/null | awk '{print $2}')
        if [ "$m" = "2" ]; then report_pass "profile installs a seccomp filter"
        else report_fail "profile installs a seccomp filter" "Seccomp=2" "Seccomp=$m" "no syscall filter"; fi

        m0=$("$ZISH" --profile none -c 'grep ^Seccomp: /proc/self/status' 2>/dev/null | awk '{print $2}')
        if [ "$m0" = "0" ]; then report_pass "no filter without a profile"
        else report_fail "no filter without a profile" "Seccomp=0" "Seccomp=$m0" "filter leaked to none"; fi

        # ptrace is actually denied (not just the filter present). strace uses
        # PTRACE_TRACEME; under the profile it must fail rather than trace.
        if command -v strace >/dev/null 2>&1; then
            if "$ZISH" --profile readonly -c 'strace /bin/true' >/dev/null 2>&1; then
                report_fail "profile denies ptrace" "strace fails" "strace traced" "ptrace not blocked"
            else
                report_pass "profile denies ptrace"
            fi
        else
            SKIP=$((SKIP + 1))
        fi
    else
        SKIP=$((SKIP + 3))
    fi

    # --allow-write is what makes wrapping an agent harness possible: the
    # harness needs its own state directory writable or it fails in ways that
    # look like harness bugs. The grant must be exactly the named root.
    sbx_root=$(mktemp -d)
    if "$ZISH" --profile readonly --allow-write "$sbx_root" -c "echo x > $sbx_root/f" >/dev/null 2>&1 && [ -e "$sbx_root/f" ]; then
        report_pass "allow-write grants the named root"
    else
        report_fail "allow-write grants the named root" "write allowed" "write refused" "grant not applied"
    fi
    # A sibling of the granted root must stay denied — a rule that leaked to
    # the parent directory would silently widen every recipe using this flag.
    if "$ZISH" --profile readonly --allow-write "$sbx_root" -c "echo x > $sbx_root/../zish_sbx_sibling" >/dev/null 2>&1 \
       && [ -e "$(dirname "$sbx_root")/zish_sbx_sibling" ]; then
        rm -f "$(dirname "$sbx_root")/zish_sbx_sibling"
        report_fail "allow-write does not leak to the parent" "sibling refused" "sibling written" "grant too wide"
    else
        report_pass "allow-write does not leak to the parent"
    fi
    rm -rf "$sbx_root"

    # A root that cannot be granted is fatal, not skipped: quietly narrowing
    # the sandbox hands the caller a session that fails later, elsewhere.
    if "$ZISH" --profile readonly --allow-write /nonexistent/zish_sbx -c 'echo ran' >/dev/null 2>&1; then
        report_fail "allow-write rejects a missing path" "exit != 0" "ran anyway" "fail-closed"
    else
        report_pass "allow-write rejects a missing path"
    fi
else
    SKIP=$((SKIP + 7))
fi

# --allow-write without a restrictive profile promises a grant that nothing
# enforces. Refuse rather than imply it was honoured. Needs no kernel support.
if selected "allow-write requires a profile"; then
    if "$ZISH" --allow-write /tmp -c 'echo ran' >/dev/null 2>&1 \
       || "$ZISH" --profile none --allow-write /tmp -c 'echo ran' >/dev/null 2>&1; then
        report_fail "allow-write requires a profile" "exit != 0" "ran anyway" "fail-closed"
    else
        report_pass "allow-write requires a profile"
    fi
else
    SKIP=$((SKIP + 1))
fi

# An unknown profile must be refused, not silently ignored — a caller that
# asked for a sandbox and did not get one is worse off than one that never did.
if selected "unknown profile is refused"; then
    if "$ZISH" --profile bogus -c 'echo ran' >/dev/null 2>&1; then
        report_fail "unknown profile is refused" "exit != 0" "ran anyway" "fail-closed"
    else
        report_pass "unknown profile is refused"
    fi
else
    SKIP=$((SKIP + 1))
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "test builtin"
# ---------------------------------------------------------------------------
# `test` had three implementations, and the *fast path* was the more capable
# one — it handled `!`, `-a`/`-o` and -nt/-ot/-ef; builtins.testCmd handled
# none of them. The fast path bails whenever an operand is quoted, and the
# parser normalises "$x" to ${x}, so adding quotes flipped the answer:
#
#     [ ! -f /nonexistent ]  -> fast path -> true   (correct)
#     [ ! -f "$missing" ]    -> testCmd   -> false  (wrong, silently)
same_as_bash "test ! with quoted empty"   '[ ! -f "$missing" ] && echo T || echo F'
same_as_bash "test ! with literal path"   '[ ! -f /nonexistent ] && echo T || echo F'
same_as_bash "test ! -z quoted"           '[ ! -z "x" ] && echo T || echo F'
same_as_bash "test -a grouping"           '[ a = a -a b = b ] && echo T || echo F'
same_as_bash "test -o grouping"           '[ a = a -o b = c ] && echo T || echo F'
same_as_bash "test ! with -a"             '[ ! -f /nonexistent -a -d /tmp ] && echo T || echo F'
same_as_bash "test bare string"           '[ x ] && echo T || echo F'
same_as_bash "test empty string"          '[ "" ] && echo T || echo F'
same_as_bash "test word form"             'test ! -f /nonexistent && echo T || echo F'
same_as_bash "test numeric compare"       '[ 2 -gt 1 ] && echo T || echo F'
same_as_bash "test string compare"        '[ "$u" = "" ] && echo T || echo F'

# ---------------------------------------------------------------------------
printf '\n%s\n' "arithmetic variables"
# ---------------------------------------------------------------------------
# ArithParser had no case for '$', so it raised SyntaxError, which
# evaluateArithmetic silently converts to 0. It only appeared to work because
# the outer expander usually substituted $x first — but not for a word
# containing '*'. Every positional parameter in arithmetic was 0.
same_as_bash "arith \$var with +"      'x=6; echo $(($x + 2))'
same_as_bash "arith \$var with *"      'x=6; echo $(($x * 2))'
same_as_bash "arith \$var with /"      'x=6; echo $(($x / 2))'
same_as_bash "arith braced \${x}"      'x=6; echo $((${x} * 2))'
same_as_bash "arith two \$vars"        'x=6; y=2; echo $(($x * $y))'
same_as_bash "arith positional"        'set -- 4; echo $(($1 * 2))'
same_as_bash "arith positional func"   'double() { echo $(($1 * 2)); }; for i in 1 2 3; do double $i; done'
same_as_bash "arith bare identifier"   'x=6; echo $((x * 2))'
same_as_bash "arith literal"           'echo $((3 * 2))'

# ---------------------------------------------------------------------------
printf '\n%s\n' "feats"
# ---------------------------------------------------------------------------
# A feat is an exec'd binary, resolved as a plain command so `calc 2+2` works
# rather than only `feat run calc 2+2`. It must stay a *fallback*: a feat may
# never shadow a real command, or installing one changes what a script means.
# These skip when the feats aren't staged (make feats).
if [ -x "$HOME/.zish/feats/standard/calc/bin/calc" ]; then
    expect "feat as bare command"      $'1.5'    0 'calc 3/2'
    expect "feat float math"           $'9'      0 'calc "(1+2)*3"'
    expect "feat via feat run"         $'0.25'   0 "feat run calc '1/4'"
    expect "feat reads stdin"          $'2'      0 'echo 1+1 | calc'
    expect "real command beats feat"   $'ok'     0 'echo ok'
    expect "calc rejects trailing junk" $'1'     0 'calc "2+2 oops" >/dev/null 2>&1; echo $?'
    expect "calc divide by zero"       $'1'      0 'calc 1/0 >/dev/null 2>&1; echo $?'
else
    SKIP=$((SKIP + 7))
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "session trace (fd 3)"
# ---------------------------------------------------------------------------
# A harness opens fd 3 and gets one JSON record per top-level command. The
# whole point is that it never has to parse stdout, so the invariants are:
# stdout is untouched, nothing is emitted when fd 3 is closed, and internals
# (rc sourcing, command substitution) stay out of the trace.

# trace NAME EXPECTED SCRIPT  — EXPECTED is matched against the record stream
trace_case() {
    local name="$1" want="$2" script="$3"
    selected "$name" || { SKIP=$((SKIP + 1)); return; }
    local out="$WORK/trace.jsonl"
    rm -f "$out"
    (cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" -c "$script" >/dev/null 2>&1 3>"$out")
    local got
    got=$(python3 -c "
import sys, json
try:
    print(' '.join(json.loads(l)['cmd'] for l in open('$out') if l.strip()))
except Exception as e:
    print('PARSE-ERROR', e)
" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        report_pass "$name"
    else
        report_fail "$name" "$want" "$got" "$script"
    fi
}

expect "no trace when fd 3 closed"  $'ok' 0 'echo ok'
trace_case "records the command"    'echo hi'          'echo hi'
trace_case "hides command subst"    'x=$(echo sub)'    'x=$(echo sub)'
trace_case "records each statement" 'echo a; echo b'   'echo a; echo b'

expect "trace keeps stdout clean"   $'just-this' 0 'echo just-this'

# A command must not be able to write to the trace channel. It is zish's
# private report to whoever launched it; if a forked child inherits the raw
# descriptor, `>&3` forges a record the harness parses as zish's own, so a
# hostile command could describe a clean session over a dirty one. The
# descriptor is relocated with close-on-exec so only zish reaches it.
if selected "trace cannot be forged by a child"; then
    rm -f "$WORK/t.jsonl"
    # The forged text would also appear inside zish's own record of the
    # command (the record echoes the command line back), so match on shape:
    # a genuine record is a line beginning `{"ts":`. Any other line is a raw
    # write the child slipped in.
    (cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" -c '/bin/sh -c "echo INJECTED >&3" 2>/dev/null' >/dev/null 2>&1 3>"$WORK/t.jsonl")
    # grep -vc prints the count but exits 1 when it is zero, so no `|| echo 0`
    # (that would append a second line and defeat the check).
    stray=$(grep -vc '^{"ts":' "$WORK/t.jsonl")
    if [ "$stray" != "0" ]; then
        report_fail "trace cannot be forged by a child" "only {\"ts\":…} records" "$stray stray line(s)" "forgeable trace"
    else
        report_pass "trace cannot be forged by a child"
    fi
fi

# A command must not be able to inject a second record by splitting the JSON.
# The cmd and cwd fields carry arbitrary bytes — a newline plus a `}` and a
# fresh `{"ts":...` would forge a record if they were not escaped. Craft both
# a hostile command and a hostile directory name and require every emitted
# line to parse as one JSON object.
if selected "trace resists json injection"; then
    rm -f "$WORK/inj.jsonl"
    evil=$'x","exit":0}\n{"ts":0,"cmd":"INJECTED'
    injdir="$WORK/$(printf 'd\ndir')"
    mkdir -p "$injdir" 2>/dev/null || injdir="$WORK"
    (cd "$injdir" && timeout 10 "$OLDPWD/$ZISH" -c "echo '$evil'" >/dev/null 2>&1 3>"$WORK/inj.jsonl")
    res=$(python3 -c "
import json,sys
n=0
for ln in open('$WORK/inj.jsonl'):
    ln=ln.rstrip('\n')
    if not ln: continue
    try: json.loads(ln); n+=1
    except Exception: print('UNPARSEABLE'); sys.exit()
print('ok' if n>=1 else 'empty')
" 2>&1)
    if [ "$res" = "ok" ]; then report_pass "trace resists json injection"
    else report_fail "trace resists json injection" "every line one JSON object" "$res" "log injection"; fi
fi

# The trace must attest which profile was enforced, so a harness can confirm
# the session it launched is the one it is reading rather than trust the flag
# it passed. Read it back with the sandbox off (needs no kernel support).
if selected "trace records the sandbox profile"; then
    rm -f "$WORK/sb.jsonl"
    (cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" --profile none -c 'echo hi' >/dev/null 2>&1 3>"$WORK/sb.jsonl")
    got=$(python3 -c "import json;print(json.load(open('$WORK/sb.jsonl')).get('sandbox','MISSING'))" 2>/dev/null)
    if [ "$got" = "none" ]; then report_pass "trace records the sandbox profile"
    else report_fail "trace records the sandbox profile" "sandbox=none" "sandbox=$got" "no attestation"; fi
fi

# exit status and duration must be real, not placeholders
if selected "trace exit and timing"; then
    rm -f "$WORK/t.jsonl"
    (cd "$WORK" && timeout 10 "$OLDPWD/$ZISH" -c 'sleep 0.2; false' >/dev/null 2>&1 3>"$WORK/t.jsonl")
    res=$(python3 -c "
import json
r = json.load(open('$WORK/t.jsonl'))
print('ok' if r['exit'] == 1 and r['ms'] >= 150 else f\"exit={r['exit']} ms={r['ms']}\")
" 2>/dev/null)
    if [ "$res" = "ok" ]; then report_pass "trace exit and timing"
    else report_fail "trace exit and timing" "exit=1 ms>=150" "$res" "sleep 0.2; false"; fi
fi

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
# A numeric-fd redirect (`3>file`) must not clobber the shell's own stdin. The
# shell parked its fd backups at 3/4/5 via plain dup(); `true 3>file` then
# dup2'd the file onto fd 3 — the stdin backup — and the restore installed the
# write-only file as the shell's fd 0, so the next `read` got EOF. Backups now
# live at fd>=10 with close-on-exec. Fed 'hi' on stdin, read must still see it.
expect "fd redirect does not clobber stdin" $'got=hi' 0 'printf "hi\n" | { true 3>/tmp/zish_fdc_$$; read x; echo got=$x; }'
expect "high fd redirect does not clobber"  $'got=ok' 0 'printf "ok\n" | { true 4>/tmp/zish_fdc_$$ 5>/tmp/zish_fdd_$$; read x; echo got=$x; }'

# A heredoc must never write through a symlink planted in world-writable /tmp.
# The old scheme used a predictable name (/tmp/zish_heredoc_e_<ms>_1) opened
# with O_CREAT|O_TRUNC and no O_EXCL, so pre-planting a symlink to a victim
# file made the heredoc body overwrite it — a reliable arbitrary-file-write
# on a shared host. Spray the millisecond window (which clobbered the old code
# every run) and require the victim untouched. Fixed by random names + O_EXCL.
if selected "heredoc resists /tmp symlink attack"; then
    v=$(mktemp); printf 'SACRED' > "$v"
    now=$(date +%s%3N 2>/dev/null || echo 0)
    for d in $(seq 0 400); do ln -sf "$v" "/tmp/zish_heredoc_e_$((now+d))_1" 2>/dev/null; done
    "$OLDPWD/$ZISH" -c 'cat <<EOF >/dev/null
PWNED
EOF' >/dev/null 2>&1
    if [ "$(cat "$v")" = "SACRED" ]; then report_pass "heredoc resists /tmp symlink attack"
    else report_fail "heredoc resists /tmp symlink attack" "victim untouched" "victim overwritten" "arbitrary file write"; fi
    rm -f /tmp/zish_heredoc_e_* "$v"
fi
same_as_bash "heredoc still works"     'cat <<EOF
line1
line2
EOF'

# Heredocs were rewritten by a byte-level pre-pass over the raw command text
# before the lexer ran, so it had to re-derive quoting and line structure and
# got both wrong. Four consequences, all fixed 2026-08-19:
#   1. everything after the delimiter WORD on that line was silently dropped,
#      so `cat <<A >out` wrote to stdout and never created the file (exit 0),
#   2. the delimiter scan stopped only at whitespace, so `;`/`|` were absorbed
#      into the delimiter and it never matched,
#   3. only the first heredoc on a line was processed, the second leaked as
#      commands,
#   4. the `<<` scan was quote-blind, so a literal `<<` in a string hid the
#      real heredoc later in the script.
same_as_bash "heredoc then redirect"   'cat <<A >hd_out.txt
one
A
cat hd_out.txt'
same_as_bash "heredoc then pipe"       'cat <<A | tr a-z A-Z
one
A'
same_as_bash "heredoc then &&"         'cat <<A && echo tail_ran
one
A'
same_as_bash "heredoc then semicolon"  'cat <<A; echo tail
one
A'
same_as_bash "two heredocs one line"   'cat <<A ; cat <<B
one
A
two
B'
same_as_bash "literal << then heredoc" 'echo "lit << here"
cat <<E
body
E'
same_as_bash "<< inside single quotes" "echo 'a << b'"
same_as_bash "<< in comment"           '# a << b
echo ok'
same_as_bash "heredoc quoted delim"    "cat <<'E'
raw \$novar
E"

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
# Command substitution captures via an unlinked temp file, single-threaded. The
# cases that broke earlier designs: >64KB output would deadlock a naive pipe
# (nothing drains while the shell waitpids), and nested substitution corrupted
# output when the buffered stdout writer pwrote at a stale offset into the
# seekable capture file. Both must match bash exactly.
same_as_bash "cmdsubst nested"         'echo "[$(echo $(echo deep))]"'
same_as_bash "cmdsubst nested x3"      'echo "[$(echo $(echo $(echo x)))]"'
expect "cmdsubst >64KB external"       $'200000' 0 'x=$(head -c 200000 /dev/zero | tr "\0" x); echo ${#x}'
expect "cmdsubst >64KB in-process"     $'319999' 0 'x=$(for i in $(seq 1 20000); do echo padding-padding; done); echo ${#x}'
expect "cmdsubst leaves no temp"       $'clean'  0 'x=$(echo hi); ls /tmp/zish_capture_* >/dev/null 2>&1 && echo dirty || echo clean'
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

# --- one escape decoder: echo -e (fast path + builtin), printf format, %b ---
# The three copies had drifted: the echo builtin (hit when an arg contains
# ${...}) knew only \n \t \r \0, so `echo -e "\a"` beeped but
# `echo -e "${x}\a"` printed a literal \a. One decoder now serves all of them.
same_as_bash "echo -e full escape set"    "echo -e '\a\b\t\n\r\v\f\e\\\\'"
same_as_bash "echo -e via variable"       'x=pre; echo -e "${x}\t\a\x41\0101"'
same_as_bash "echo -e backslash-c stops"  "echo -e 'a\cb c'"
same_as_bash "echo -e \\c via variable"   'x=pre; echo -e "${x}a\cb c"'
same_as_bash "echo without -e is literal" "echo '\a\t\n'"
same_as_bash "echo no -e via variable"    'x=lit; echo "${x}\a\t"'
same_as_bash "printf %b escape set"       'printf "%b" "\a\t\x41"'
same_as_bash "printf %b \\c aborts all"   'printf "%b-" "a\cb" "x"; printf end'
same_as_bash "printf fmt unknown escape"  'printf "\q\e\x4Z"'
same_as_bash "printf fmt vs %b octal"     'printf "\101Z \0101Z"; printf "%b" "\101Z \0101Z"'
same_as_bash "echo -e octal + hex edges"  'echo -e "\0101Z \101Z \x4Z \xgZ \08Z \0400Z"'

# --- one word-expansion pipeline: for-loop words expand before iteration ---
# bash expands the ENTIRE for-word list before the first iteration; zish used
# to expand lazily per word, so a body mutating a variable used in a LATER
# word iterated over the wrong values.
same_as_bash "for words expand up front"  'v=x; for w in $v ${v}2; do v=CHANGED; printf "%s " "$w"; done'
same_as_bash "for brace expansion"        'for w in a{1,2} b; do printf "%s " "$w"; done'
same_as_bash "for glob words"             'mkdir -p g && touch g/a.zz g/b.zz; for f in g/*.zz; do printf "%s " "$f"; done'
same_as_bash "for custom IFS split"       'IFS=:; for x in a:b:c; do printf "[%s]" "$x"; done'
same_as_bash "for quoted word one field"  'for x in "a b" c; do printf "[%s]" "$x"; done'
same_as_bash "for empty word list"        'for x in; do echo no; done'
same_as_bash "for escaped dollar literal" 'for x in \$HOME; do echo "$x"; done'
same_as_bash "for cmdsubst split + break" 'for x in $(echo a b) lit; do printf "[%s]" "$x"; done'
same_as_bash "for continue N"             'for i in 1 2 3; do for j in a b; do continue 2; done; echo "$i"; done'
same_as_bash "for nested same variable"   'for x in 1 2; do for x in a b; do printf %s "$x"; done; printf "[%s]" "$x"; done'

# Redirections applied to a COMPOUND command (while/for/if/brace/subshell).
# Regression: the parser attached redirects to simple commands only, so the
# canonical `while read x; do ..; done < file` idiom was a parse error.
same_as_bash "while-read redir from file"  'printf "1 2\n3 4\n" > rf.$$; while read -r a b; do printf "%s+%s " "$a" "$b"; done < rf.$$; rm -f rf.$$'
same_as_bash "while-read count from file"  'printf "a\nb\nc\n" > rc.$$; n=0; while read -r x; do n=$((n+1)); done < rc.$$; echo $n; rm -f rc.$$'
same_as_bash "for redir stdin from file"   'printf "z\n" > rf2.$$; for i in 1 2; do printf "%s " "$i"; done < rf2.$$; rm -f rf2.$$'
same_as_bash "if redir stdin from file"    'printf "x\n" > ri.$$; if true; then cat; fi < ri.$$; rm -f ri.$$'
same_as_bash "brace group redir in"        'printf "one\ntwo\n" > rb.$$; { read -r a; read -r b; } < rb.$$; echo "$a|$b"; rm -f rb.$$'
same_as_bash "for redir stdout to file"    'for i in a b c; do echo "$i"; done > ro.$$; cat ro.$$; rm -f ro.$$'
same_as_bash "subshell redir in"           'printf "hi\n" > rs.$$; ( cat ) < rs.$$; rm -f rs.$$'
same_as_bash "[[ ]] with redirect"         '[[ -n x ]] 2>/dev/null && echo yes'
same_as_bash "(( )) with redirect"         '(( 1 + 1 )) 2>/dev/null && echo ok'
same_as_bash "[[ ]] redirect stdout rc"    '[[ -f /nonexistent ]] > /dev/null; echo rc=$?'

# `for x` with no list iterates over "$@" as a QUOTED expansion (each positional
# one field), not a literal word that leaks the quote characters.
same_as_bash "for no-list over quoted \$@" 'set -- "x y" z; for i; do echo "[$i]"; done'
same_as_bash "for no-list simple"          'set -- a b c; for i; do printf "%s." "$i"; done'
same_as_bash "for no-list no-semicolon"    'set -- "a b" "c d"; for i do echo "<$i>"; done'

# `read` builtin: the seekable fast path (block read + lseek-back) must be
# byte-for-byte identical to the byte path and to bash. The critical invariant
# is that read consumes EXACTLY one line — a following reader sees the rest.
same_as_bash "read then cat remainder"     'printf "L1\nL2\nL3\n" > rr.$$; { read -r a; echo "first=$a"; cat; } < rr.$$; rm -f rr.$$'
same_as_bash "read x2 then cat remainder"  'printf "L1\nL2\nL3\n" > rr2.$$; { read -r a; read -r b; echo "$a/$b"; cat; } < rr2.$$; rm -f rr2.$$'
same_as_bash "read partial last line rc"   'printf "a\nb" > rp.$$; while read -r x; do echo "got:$x"; done < rp.$$; echo "rc-loop-done"; rm -f rp.$$'
same_as_bash "read blank lines preserved"  'printf "a\n\nb\n" > rbl.$$; while read -r x; do echo "<$x>"; done < rbl.$$; rm -f rbl.$$'
same_as_bash "read empty file rc"          ': > re.$$; if read -r x < re.$$; then echo yes; else echo no; fi; rm -f re.$$'
same_as_bash "read multi-var last rest"    'printf "one two three four\n" > rmv.$$; read -r a b c < rmv.$$; echo "$a|$b|$c"; rm -f rmv.$$'
same_as_bash "read from pipe (byte path)"  'printf "p1\np2\n" | while read -r x; do echo "got:$x"; done'
# Growable line buffer: a line longer than one 4KB block must read whole (was
# truncated at 4095 before LineReader) and leave the fd correctly positioned.
same_as_bash "read long line (>4KB)"       'head -c 5000 /dev/zero | tr "\0" A > rlong; echo >> rlong; echo tail >> rlong; read -r x < rlong; echo "${#x}"; rm -f rlong'
same_as_bash "read long line then next"    'head -c 5000 /dev/zero | tr "\0" A > rlong2; echo >> rlong2; echo tail >> rlong2; { read -r x; read -r y; echo "$y"; } < rlong2; rm -f rlong2'

# mapfile / readarray share the LineReader owner. Verify the array semantics and
# that -n early-stop reconciles the fd (a later reader sees the unread lines).
same_as_bash "mapfile -t basic"            'printf "l1\nl2\nl3\n" > mf.$$; mapfile -t a < mf.$$; printf "%s\n" "${a[@]}"; echo "n=${#a[@]}"; rm -f mf.$$'
same_as_bash "mapfile keeps delimiter"     'printf "l1\nl2\n" > mf2.$$; mapfile a < mf2.$$; printf "[%s]" "${a[@]}"; rm -f mf2.$$'
same_as_bash "mapfile -n limit"            'printf "l1\nl2\nl3\n" > mf3.$$; mapfile -n 2 -t a < mf3.$$; echo "${#a[@]}:${a[0]}:${a[1]}"; rm -f mf3.$$'
same_as_bash "mapfile -s skip"             'printf "l1\nl2\nl3\n" > mf4.$$; mapfile -s 1 -t a < mf4.$$; printf "%s," "${a[@]}"; rm -f mf4.$$'
same_as_bash "mapfile partial last line"   'printf "p\nq" > mf5.$$; mapfile -t a < mf5.$$; echo "${#a[@]}:${a[1]}"; rm -f mf5.$$'
same_as_bash "mapfile -n then read rest"   'printf "l1\nl2\nl3\nl4\n" > mf6.$$; { mapfile -n 2 -t two; cat; } < mf6.$$; rm -f mf6.$$'

# Fast-path caps must FALL BACK to the full path, never silently truncate.
same_as_bash "[ ] beyond 8 args"           '[ a = b -o c = d -o e = e ] && echo yes || echo no'
same_as_bash "[ ] many -a args"            '[ a = a -a b = b -a c = c -a d = d ] && echo y || echo n'
same_as_bash "echo 17 args"                'echo a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17'
same_as_bash "echo long quoted arg"        'echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
# -x / -g / -k on a FIFO must not open (open blocks forever) — use a real path.
same_as_bash "[ -x on non-exec file"       '[ -x /etc/hostname ] && echo yes || echo no'
# The FIFO itself: old zish hung here (open with no writer blocks); harness
# timeout makes a regression fail red. bash and fixed zish both return 1 fast.
same_as_bash "[ -x fifo no hang"           'mkfifo hangfifo; [ -x hangfifo ]; echo $?; rm -f hangfifo'

# ---------------------------------------------------------------------------
printf '\n%s\n' "para feat"
# ---------------------------------------------------------------------------
# The parallel runner is a feat (separate binary), so it is only tested when
# staged (`make feats`). It fans jobs out N-at-a-time with per-job grouped
# output in input order, execs argv directly (no shell → no injection), and
# exits with the failure count.
PAR="$HOME/.zish/feats/standard/para/bin/para"
if [ -x "$PAR" ]; then
    got=$("$PAR" echo {} ::: a b c 2>/dev/null)
    [ "$got" = $'a\nb\nc' ] && report_pass "para: {} substitution + order" \
        || report_fail "para: {} substitution + order" "a|b|c" "$(echo "$got" | tr '\n' '|')" "grouped output"
    got=$(printf '%s\n' x y | "$PAR" echo got {} 2>/dev/null)
    [ "$got" = $'got x\ngot y' ] && report_pass "para: stdin items" \
        || report_fail "para: stdin items" "got x|got y" "$(echo "$got" | tr '\n' '|')" "stdin"
    # an item with metacharacters must stay one argument
    rm -f "$WORK/PWNED"
    "$PAR" echo ::: "z;touch $WORK/PWNED" >/dev/null 2>&1
    [ -e "$WORK/PWNED" ] && report_fail "para: no shell injection" "no file" "item executed" "injection" \
        || report_pass "para: no shell injection"
    # exit status = number of failed jobs
    "$PAR" sh -c 'exit 0' ::: 1 2 3 >/dev/null 2>&1
    [ $? -eq 0 ] && report_pass "para: exit 0 when all succeed" \
        || report_fail "para: exit 0 when all succeed" "0" "$?" "exit status"
    "$PAR" sh -c 'test {} -eq 0' ::: 0 1 1 >/dev/null 2>&1
    [ $? -eq 2 ] && report_pass "para: exit = failure count" \
        || report_fail "para: exit = failure count" "2" "$?" "exit status"
    # -n N batches items per command, matching xargs -n exactly
    got=$(seq 1 5 | "$PAR" -n 2 echo 2>/dev/null)
    want=$(seq 1 5 | xargs -n 2 echo 2>/dev/null)
    [ "$got" = "$want" ] && report_pass "para: -n matches xargs -n" \
        || report_fail "para: -n matches xargs -n" "$(echo "$want" | tr '\n' '|')" "$(echo "$got" | tr '\n' '|')" "batching"
    # {} with -n>1 is rejected, not silently wrong
    "$PAR" -n 2 echo {} ::: a b c >/dev/null 2>&1
    [ $? -eq 2 ] && report_pass "para: {} with -n>1 rejected" \
        || report_fail "para: {} with -n>1 rejected" "exit 2" "$?" "ambiguous combo"
    # no leftover temp files
    ls /tmp/zish_para_* >/dev/null 2>&1 \
        && report_fail "para: no leftover temp" "clean" "temp left" "cleanup" \
        || report_pass "para: no leftover temp"
else
    SKIP=$((SKIP + 8))
fi

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
