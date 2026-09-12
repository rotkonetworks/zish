#!/usr/bin/env bash
# agent tests — the model loop, driven entirely offline through its `--mock`
# seam: a JSONL file of canned {"status":N,"body":"<json>"} replies, consumed
# in order, so no socket is opened, no key is needed, and nothing depends on a
# clock. What is pinned is the observable contract of the feat: the session
# loop's frames (a `run` per tool call, a `say` carrying the model's text or a
# diagnostic, `done` last), that a tool result is fed back for another turn,
# the turn budget, the usage-error paths (a frame from the session loop, exit 2
# from a one-shot verb), and — process-level — that a stdout reader already
# gone kills the process with SIGPIPE (141) instead of the agent writing into a
# dead pipe and exiting 0.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/agent-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T"                 # no key file lives here; --mock needs none
mkdir -p "$T/.zish"
# hermetic: the caller's shell must not pick a backend/model/budget for us.
unset ZISH_AGENT_ENDPOINT ZISH_AGENT_BACKEND ZISH_AGENT_MODEL ZISH_AGENT_MAX_TURNS \
      ZISH_AGENT_TIMEOUT ZISH_AGENT_MAX_TOKENS ZISH_ASK_META

echo "building agent..."
# The feat under test is the one `zig build` installed — a suite that picks its
# own compile flags can validate a differently linked binary than ships, which
# is what every suite here used to do.
FEAT_BIN=${FEAT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/share/zish/feats/standard}
A="$T/agent"
cp "$FEAT_BIN/agent/bin/agent" "$A" || { echo "FAIL: $FEAT_BIN/agent not built — run: zig build -Dfeats=all"; exit 1; }
# It must stay libc-free. That used to be asserted by passing no -lc here; the
# decision now lives in build.zig (only `para` links libc), so assert the
# property on the artefact instead.
if command -v file >/dev/null 2>&1 && file "$A" | grep -q 'dynamically linked'; then
    echo "FAIL: agent links libc (it must not)"; exit 1
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ---- mock replies -----------------------------------------------------------
# A text turn, a tool call (whose `arguments` is itself a JSON string carrying
# the command), a turn that reports token usage, and two error shapes.
cat > "$T/text.jsonl" <<'JSONL'
{"status":200,"body":"{\"choices\":[{\"message\":{\"content\":\"hello from the model\"}}]}"}
JSONL
cat > "$T/tool_text.jsonl" <<'JSONL'
{"status":200,"body":"{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"echo magic\\\"}\"}}]}}]}"}
{"status":200,"body":"{\"choices\":[{\"message\":{\"content\":\"hello from the model\"}}]}"}
JSONL
cat > "$T/usage.jsonl" <<'JSONL'
{"status":200,"body":"{\"choices\":[{\"message\":{\"content\":\"done\"}}],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":5}}"}
JSONL
cat > "$T/http401.jsonl" <<'JSONL'
{"status":401,"body":"{\"error\":{\"message\":\"nope\"}}"}
JSONL
cat > "$T/apierr.jsonl" <<'JSONL'
{"status":200,"body":"{\"error\":{\"message\":\"boom\"}}"}
JSONL

# SIGPIPE regression: a filter must die (141) when the reader of its stdout is
# gone, not swallow EPIPE and exit 0. A pipe whose read end is closed *before*
# exec fails the first write deterministically; `| head -c1` does not for output
# under the 64 KiB pipe buffer — the write lands before the reader exits.
sigpipe_status() {
    python3 -c 'import os,sys
r, w = os.pipe(); os.close(r)
os.dup2(w, 1); os.close(w)
os.execvp(sys.argv[1], sys.argv[1:])' "$@" 2>/dev/null
}

echo "== a completed turn: the model's text as a say frame, then done =="
o=$("$A" --mock "$T/text.jsonl" "say hi" </dev/null); rc=$?
want=$(printf '%s\n%s\n' '{"t":"say","text":"hello from the model"}' '{"t":"done"}')
[ "$rc" -eq 0 ] && ok "completed turn -> exit 0" || bad "exit $rc"
[ "$o" = "$want" ] && ok "say + done frames, no run frame" || bad "got '$o'"

echo "== a long query: argv words join into one query, same single turn =="
o=$("$A" --mock "$T/text.jsonl" say hello "to" you </dev/null)
[ "$o" = "$want" ] && ok "multi-word query still one turn" || bad "got '$o'"

echo "== the turn budget: --turns 1 ends after the tool call hits the limit =="
o=$(printf '%s\n%s\n' '{"t":"hello"}' '{"code":0,"out":"ok"}' \
    | "$A" --turns 1 --mock "$T/tool_text.jsonl" go); rc=$?
want=$(printf '%s\n%s\n%s\n' '{"t":"run","cmd":"echo magic"}' \
       '{"t":"say","text":"agent: reached the turn limit"}' '{"t":"done"}')
[ "$rc" -eq 0 ] && ok "turn limit -> exit 0" || bad "exit $rc"
[ "$o" = "$want" ] && ok "run frame carries the command; budget reports the limit" || bad "got '$o'"

echo "== the tool result is fed back: turn 2 consumes the mock's next reply =="
o=$(printf '%s\n%s\n' '{"t":"hello"}' '{"code":0,"out":"ok"}' \
    | "$A" --turns 4 --mock "$T/tool_text.jsonl" go)
want=$(printf '%s\n%s\n%s\n' '{"t":"run","cmd":"echo magic"}' \
       '{"t":"say","text":"hello from the model"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "tool call then final text (loop continued)" || bad "got '$o'"

echo "== usage: --turns without a value, and with a non-numeric one =="
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: usage: agent [-m model] [--turns N] [--mock file] <query>"}' '{"t":"done"}')
o=$("$A" --turns </dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$o" = "$want" ] && ok "missing value -> usage frame, exit 0" || bad "rc=$rc got '$o'"
o=$("$A" --turns nope --mock "$T/text.jsonl" q </dev/null)
[ "$o" = "$want" ] && ok "non-numeric value -> usage frame" || bad "got '$o'"

echo "== usage: no query at all is its own frame =="
o=$("$A" --mock "$T/text.jsonl" </dev/null)
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: no query given"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "empty query -> diagnostic frame" || bad "got '$o'"

echo "== --ask: a one-shot completion, plain text on stdout =="
o=$("$A" --ask --mock "$T/text.jsonl" "what is up" </dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$o" = "hello from the model" ] && ok "--ask prints the model text, exit 0" || bad "rc=$rc got '$o'"

echo "== --judge with no rubric/subject: usage error on stderr, exit 2 =="
o=$("$A" --judge </dev/null 2>"$T/err"); rc=$?
[ "$rc" -eq 2 ] && ok "judge usage -> exit 2" || bad "exit $rc (want 2)"
[ -z "$o" ] && ok "nothing on stdout" || bad "stdout: '$o'"
grep -q 'usage: agent --judge' "$T/err" && ok "usage text on stderr" || bad "stderr: $(cat "$T/err")"

echo "== no key file and no --mock: fail closed before any request =="
o=$("$A" --turns 1 "hi" </dev/null)
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: no API key at ~/.zish/openrouter.key (create it, chmod 600)"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "missing key -> diagnostic frame, no request" || bad "got '$o'"

echo "== --mock is the offline seam: curl is never exec'd =="
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG:?}"
exit 1
SH
chmod +x "$T/stub/curl"
: > "$T/curl.log"
STUB_LOG="$T/curl.log" PATH="$T/stub:$PATH" "$A" --mock "$T/text.jsonl" "say hi" </dev/null >/dev/null
[ ! -s "$T/curl.log" ] && ok "no curl under --mock (no socket opened)" || bad "curl ran: $(cat "$T/curl.log")"

echo "== a non-2xx status is reported, not retried forever =="
o=$("$A" --mock "$T/http401.jsonl" q </dev/null)
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: HTTP 401 from model API"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "401 -> HTTP status frame" || bad "got '$o'"

echo "== an API error body is surfaced verbatim =="
o=$("$A" --mock "$T/apierr.jsonl" q </dev/null)
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: API error: boom"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "error body -> API error frame" || bad "got '$o'"

echo "== an unreadable mock file is reported, not crashed on =="
o=$("$A" --mock "$T/nope.jsonl" q </dev/null); rc=$?
want=$(printf '%s\n%s\n' '{"t":"say","text":"agent: could not read mock file"}' '{"t":"done"}')
[ "$rc" -eq 0 ] && [ "$o" = "$want" ] && ok "missing mock -> diagnostic frame, exit 0" || bad "rc=$rc got '$o'"

echo "== token usage is reported before the turn can end =="
o=$("$A" --mock "$T/usage.jsonl" q </dev/null)
want=$(printf '%s\n%s\n%s\n' '{"t":"usage","in":11,"out":5}' \
       '{"t":"say","text":"done"}' '{"t":"done"}')
[ "$o" = "$want" ] && ok "usage frame precedes the say" || bad "got '$o'"

echo "== SIGPIPE: stdout closed on us kills the process (141), not a quiet 0 =="
if command -v python3 >/dev/null 2>&1; then
    sigpipe_status "$A" --mock "$T/text.jsonl" "read by nobody" </dev/null
    rc=$?
    [ "$rc" -eq 141 ] && ok "mock turn with the stdout reader gone -> exit 141" || bad "closed stdout exit $rc (want 141)"
    sigpipe_status "$A" --turns </dev/null
    rc=$?
    [ "$rc" -eq 141 ] && ok "usage frame to a dead reader -> exit 141" || bad "closed stdout exit $rc (want 141)"
else
    printf '  \033[33mSKIP\033[0m SIGPIPE cases (no python3)\n'
fi

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
else printf '\033[31m%d FAILED\033[0m, %d passed\n' "$fail" "$pass"; exit 1; fi
