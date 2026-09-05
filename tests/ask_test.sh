#!/usr/bin/env bash
# ask feat — pose a question, block until answered via the file protocol.
# Hermetic: a fake "client" writes the answer file; no server/browser needed.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/ask-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T"                 # ask writes under $HOME/.zish/asks
mkdir -p "$T/.zish"

echo "building ask..."
zig build-exe -lc feats/ask/main.zig -femit-bin="$T/ask" >/dev/null 2>&1 || {
    echo "FAIL: ask does not compile"; exit 1; }
A="$T/ask"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# answer the (single) pending question with $1 once it appears
answer_with() {
  local val="$1" i=0
  while [ $i -lt 50 ]; do
    local qf; qf=$(ls "$T/.zish/asks"/*.json 2>/dev/null | head -1)
    if [ -n "$qf" ]; then
      local id; id=$(basename "$qf" .json)
      printf '%s' "$val" > "$T/.zish/asks/$id.answer"
      return 0
    fi
    sleep 0.1; i=$((i+1))
  done
  return 1
}

echo "== multiple choice: prints the chosen option's text =="
( answer_with 2 ) &
o=$("$A" -t 10 "pick one" "alpha" "beta" "gamma" "delta"); rc=$?
[ "$rc" -eq 0 ] && ok "answered -> exit 0" || bad "exit $rc"
[ "$o" = "gamma" ] && ok "index 2 -> 'gamma'" || bad "got '$o' (want gamma)"

echo "== open question: echoes the free-text answer =="
( answer_with "call it zish" ) &
o=$("$A" -t 10 "what name?"); rc=$?
[ "$o" = "call it zish" ] && ok "free text passed through" || bad "got '$o'"

echo "== pending question record is well-formed JSON with the options =="
( sleep 0.4; qf=$(ls "$T/.zish/asks"/*.json | head -1); id=$(basename "$qf" .json); \
  grep -q '"options":\["x","y"\]' "$qf" && printf 0 > "$T/.zish/asks/$id.answer" ) &
o=$("$A" -t 10 "x or y?" "x" "y")
[ "$o" = "x" ] && ok "question JSON carried the options" || bad "options not surfaced: $o"

echo "== timeout: no answer -> exit 3 =="
"$A" -t 1 "unanswered?" "a" "b" >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "timed out -> exit 3" || bad "wrong timeout exit"

echo "== usage: 1 option is rejected =="
"$A" "bad" "only-one" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "single option -> exit 2" || bad "single option not rejected"

echo "== answered questions clean up their files =="
[ -z "$(ls "$T/.zish/asks" 2>/dev/null)" ] && ok "asks dir clean after answers" || bad "stale files: $(ls "$T/.zish/asks")"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
else printf '\033[31m%d FAILED\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
