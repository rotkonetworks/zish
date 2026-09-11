#!/usr/bin/env bash
# bus feat — durable channel log: publish, read, resume, thread, filter.
# Hermetic: HOME is redirected, so the bus root is $T/.zish/bus.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/bus-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$T/.zish"

echo "building bus..."
# No -lc: the feat must stay libc-free, or the shared lib has regressed.
zig build-exe -O ReleaseFast -fstrip feats/bus/main.zig -femit-bin="$T/bus" >/dev/null 2>&1 || {
    echo "FAIL: bus does not compile without libc"; exit 1; }
B="$T/bus"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# run the feat with a captured exit code
run() { "$B" "$@" >"$T/out" 2>"$T/err"; rc=$?; }
# stdout/exit assertion
is() { # name, want_stdout, want_rc, args...
    local name="$1" want="$2" wantrc="$3"; shift 3
    run "$@"
    if [ "$(cat "$T/out")" = "$want" ] && [ "$rc" = "$wantrc" ]; then ok "$name"
    else bad "$name (want '$want'/$wantrc, got '$(cat "$T/out")'/$rc)"; fi
}

# --- usage and rejection: a bad call must be loud, never silent ---
is "no args is a usage error"    "" 2
is "unknown subcommand"          "" 2 read
is "pub without a channel"       "" 2 pub
is "read without a channel"      "" 2 read
# `#` starts a comment in every shell that will call this, so it is not a channel
# character; `-x` would be indistinguishable from a flag; `/` and `..` escape.
is "hash is not a channel"       "" 2 pub '#chan' hi
is "leading dash is not a channel" "" 2 pub -x hi
is "slash is not a channel"      "" 2 pub 'a/b' hi
is "dotdot is not a channel"     "" 2 pub '..' hi
# A label is an identity, not an address, so `@` must be accepted here.
is "tab in a label is rejected"  "" 2 pub tasks --from "$(printf 'a\tb')" hi

# --- publish ---
run pub tasks hello world
[ "$rc" = 0 ] && [ -n "$(cat "$T/out")" ] && ok "pub prints a cursor" || bad "pub prints a cursor"
C1=$(cat "$T/out")
case "$C1" in
    [0-9]*'-'*) ok "cursor is a sortable name" ;;
    *)          bad "cursor is a sortable name (got '$C1')" ;;
esac

run pub tasks --from @alice --thread t1 'threaded message'
[ "$rc" = 0 ] && ok "pub accepts an @label and a thread" || bad "pub accepts an @label and a thread"

run pub tasks --from @bob third
C3=$(cat "$T/out")
[ "$rc" = 0 ] && ok "second unthreaded pub" || bad "second unthreaded pub"

# --- read: four columns, thread column empty when unthreaded ---
run read tasks
want=$(printf 'hello world')
if [ "$(cat "$T/out" | cut -f1 | wc -l)" = 3 ] \
   && [ "$(cat "$T/out" | sed -n 1p | cut -f2,3,4)" = "alice"$'\t'$'\t'"$want" ]; then
    ok "read renders ts/from/thread/text"
else
    bad "read renders ts/from/thread/text (got '$(cat "$T/out" | head -1)')"
fi

# --- thread filter ---
run read tasks --thread t1
if [ "$(cat "$T/out" | wc -l)" = 1 ] && [ "$(cat "$T/out" | cut -f3)" = t1 ]; then
    ok "thread filter selects one thread"
else
    bad "thread filter selects one thread (got '$(cat "$T/out")')"
fi

# --- cursor resume: --after the first message yields exactly the later two ---
run read tasks --after "$C1"
if [ "$(cat "$T/out" | wc -l)" = 2 ]; then ok "resume after a cursor"
else bad "resume after a cursor (got $(cat "$T/out" | wc -l) lines)"; fi

run read tasks --after "$C3"
if [ "$(cat "$T/out" | wc -l)" = 0 ]; then ok "nothing follows the last cursor"
else bad "nothing follows the last cursor (got $(cat "$T/out" | wc -l) lines)"; fi

# --- stdin ---
printf 'from a pipe\n' | "$B" pub tasks >"$T/out" 2>"$T/err"
[ "$?" = 0 ] && ok "pub reads a piped message" || bad "pub reads a piped message"

printf '\n\n' | "$B" pub tasks >/dev/null 2>&1
[ "$?" = 2 ] && ok "an empty piped message is rejected" || bad "an empty piped message is rejected"

# --- messages that would break the record format ---
CLAST=$("$B" pub tasks --from @q "$(printf 'quote " backslash \\ tab\there')" 2>/dev/null)
[ "$?" = 0 ] && ok "pub accepts quotes, backslash and tab in the text" || bad "pub accepts quotes, backslash and tab"

run read tasks --json
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys
for line in sys.stdin:
    line=line.strip()
    if line: json.loads(line)' < "$T/out" 2>/dev/null; then
        ok "--json emits valid JSON for every record"
    else
        bad "--json emits valid JSON for every record"
    fi
else
    printf '  \033[33mSKIP\033[0m json validity (no python3)\n'
fi

# --- an absent channel is empty, not an error ---
is "reading an absent channel is empty" "" 0 read nosuchchannel
[ -d "$T/.zish/bus/nosuchchannel" ] && bad "read must not create a channel" || ok "read does not create the channel"

# --- the store is inspectable without the feat ---
# 5 publishes above: hello world, threaded, third, piped, quote/tab.
n=$(ls "$T/.zish/bus/tasks" | wc -l)
[ "$n" = 5 ] && ok "channels are directories of message files" || bad "channels are directories of message files (found $n)"
names=$(ls "$T/.zish/bus/tasks")
if [ "$names" = "$(printf '%s\n' "$names" | sort)" ]; then ok "message names sort chronologically"
else bad "message names sort chronologically"; fi

# --- print-cursor goes to stderr, so stdout stays pure data ---
"$B" read tasks --print-cursor >"$T/out" 2>"$T/err"
if [ "$(cat "$T/err")" = "$CLAST" ] && [ "$(cat "$T/out" | wc -l)" = 5 ]; then
    ok "--print-cursor writes the cursor to stderr only"
else
    bad "--print-cursor writes the cursor to stderr only (err='$(cat "$T/err")' want '$CLAST')"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n\n' "$fail" "$((pass+fail))"; exit 1
