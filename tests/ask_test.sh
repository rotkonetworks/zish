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
zig build-exe -O ReleaseFast -lc feats/ask/main.zig -femit-bin="$T/ask" >/dev/null 2>&1 || {
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

echo "== checkbox (-m): comma indices -> one option per line, ordered, deduped =="
( answer_with "2, 0,2" ) &
o=$("$A" -m -t 10 "which?" "alpha" "beta" "gamma")
[ "$o" = "$(printf 'gamma\nalpha')" ] && ok "'2, 0,2' -> gamma, alpha" || bad "got '$o'"

echo "== checkbox (-m): record carries multi:true =="
( sleep 0.4; qf=$(ls "$T/.zish/asks"/*.json | head -1); id=$(basename "$qf" .json); \
  grep -q '"multi":true' "$qf" && printf 1 > "$T/.zish/asks/$id.answer" ) &
o=$("$A" -m -t 10 "x or y?" "x" "y")
[ "$o" = "y" ] && ok "multi flag recorded, single pick works" || bad "got '$o'"

echo "== checkbox (-m): a typed Other answer is echoed verbatim =="
( answer_with "none of these" ) &
o=$("$A" -m -t 10 "which?" "a" "b")
[ "$o" = "none of these" ] && ok "free text passes through under -m" || bad "got '$o'"

echo "== checkbox (-m): out-of-range index is echoed, not silently dropped =="
( answer_with "0,7" ) &
o=$("$A" -m -t 10 "which?" "a" "b")
[ "$o" = "0,7" ] && ok "'0,7' echoed verbatim" || bad "got '$o'"

echo "== usage: -m without options is rejected =="
"$A" -m "open?" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "-m open question -> exit 2" || bad "-m without options accepted"

echo "== timeout: no answer -> exit 3 =="
"$A" -t 1 "unanswered?" "a" "b" >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "timed out -> exit 3" || bad "wrong timeout exit"

echo "== usage: 1 option is rejected =="
"$A" "bad" "only-one" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "single option -> exit 2" || bad "single option not rejected"

echo "== herdr: reports blocked with the question, releases after the answer =="
FAKE="$T/fake-herdr"; LOG="$T/herdr.log"
cat > "$FAKE" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_LOG:?}"
SH
chmod +x "$FAKE"
rm -f "$LOG"
( answer_with 1 ) &
o=$(HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$FAKE" FAKE_LOG="$LOG" "$A" -t 10 "deploy?" "no" "yes")
[ "$o" = "yes" ] && ok "answer unaffected by reporting" || bad "got '$o'"
if [ -f "$LOG" ]; then
  grep -q '^pane report-agent w1:p2 --source custom:zish-ask --agent ask --state blocked --message deploy?$' "$LOG" \
    && ok "report-agent blocked carried pane, source, and question" || bad "bad report line: $(cat "$LOG")"
  grep -q '^pane release-agent w1:p2 --source custom:zish-ask --agent ask$' "$LOG" \
    && ok "release-agent sent" || bad "no release: $(cat "$LOG")"
  [ "$(head -1 "$LOG" | cut -d' ' -f2)" = "report-agent" ] && [ "$(tail -1 "$LOG" | cut -d' ' -f2)" = "release-agent" ] \
    && ok "report precedes release" || bad "order: $(cat "$LOG")"
else
  bad "herdr never invoked"
fi

echo "== herdr: released on timeout too =="
rm -f "$LOG"
HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$FAKE" FAKE_LOG="$LOG" "$A" -t 1 "nobody home?" "a" "b" >/dev/null 2>&1
grep -q 'release-agent' "$LOG" 2>/dev/null && ok "release after timeout" || bad "no release on timeout"

echo "== herdr: released on SIGINT (files cleaned too) =="
rm -f "$LOG"
HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$FAKE" FAKE_LOG="$LOG" "$A" -t 30 "ctrl-c me?" "a" "b" >/dev/null 2>&1 &
apid=$!
sleep 0.5; kill -INT "$apid"; wait "$apid"; rc=$?
[ "$rc" -eq 130 ] && ok "SIGINT -> exit 130 (128+2)" || bad "SIGINT exit $rc"
grep -q 'release-agent' "$LOG" 2>/dev/null && ok "release after SIGINT" || bad "no release on SIGINT"
[ -z "$(ls "$T/.zish/asks" 2>/dev/null)" ] && ok "asks dir clean after SIGINT" || bad "stale files after SIGINT: $(ls "$T/.zish/asks")"

echo "== herdr: not invoked outside herdr =="
rm -f "$LOG"
( answer_with 0 ) &
o=$(HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$FAKE" FAKE_LOG="$LOG" "$A" -t 10 "outside?" "x" "y")
[ "$o" = "x" ] && [ ! -f "$LOG" ] && ok "HERDR_ENV unset -> no reporting" || bad "reported without HERDR_ENV: $(cat "$LOG" 2>/dev/null)"

echo "== herdr: a chatty reporter cannot pollute the answer =="
CHATTY="$T/chatty-herdr"
printf '#!/bin/sh\necho NOISE-OUT\necho NOISE-ERR >&2\n' > "$CHATTY"; chmod +x "$CHATTY"
( answer_with "clean" ) &
o=$(HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$CHATTY" "$A" -t 10 "free?" 2>"$T/err")
[ "$o" = "clean" ] && ! grep -q NOISE "$T/err" && ok "reporter stdout/stderr swallowed" || bad "polluted: out='$o' err='$(cat "$T/err")'"

echo "== herdr: a hung reporter is bounded, the ask still answers =="
HUNG="$T/hung-herdr"
printf '#!/bin/sh\nsleep 60\n' > "$HUNG"; chmod +x "$HUNG"
( answer_with 1 ) &
start=$(date +%s)
o=$(HERDR_ENV=1 HERDR_PANE_ID=w1:p2 HERDR_BIN_PATH="$HUNG" "$A" -t 30 "hung?" "a" "b")
el=$(( $(date +%s) - start ))
[ "$o" = "b" ] && [ "$el" -lt 15 ] && ok "hung reporter killed within bound (${el}s)" || bad "hung reporter: out='$o' took ${el}s"

echo "== answered questions clean up their files =="
[ -z "$(ls "$T/.zish/asks" 2>/dev/null)" ] && ok "asks dir clean after answers" || bad "stale files: $(ls "$T/.zish/asks")"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
else printf '\033[31m%d FAILED\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
