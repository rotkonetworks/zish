#!/usr/bin/env bash
# jevx tests — the decision-question compiler, driven offline through its
# `--mock` seam (canned {"status":N,"body":"<json>"} lines, consumed in order),
# so no socket is opened and no key is needed. Pinned: the compiled request
# (-n), the one-line output shapes, the exit-status contract (0 pass, 1 a gate
# failed, 2 could not decide), -l filtering, the -f file conventions, and that
# an HTTP error is reported as "could not decide" rather than "no".
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/jevx-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T"
mkdir -p "$T/.zish"
unset JEVX_BACKEND JEVX_ENDPOINT JEVX_MODEL OPENROUTER_API_KEY TYPESAFE_API_KEY XDG_CONFIG_HOME

# The binary under test: $JEVX if given (the standalone build: `zig build
# suite` passes its own), else what zish's `zig build` installed.
FEAT_BIN=${FEAT_BIN:-$(pwd)/zig-out/share/zish/feats/standard}
J=${JEVX:-$FEAT_BIN/jevx/bin/jevx}
case "$J" in /*) ;; *) J="$(pwd)/$J" ;; esac
[ -x "$J" ] || { echo "FAIL: $J not built — run: zig build -Dfeats=all"; exit 1; }
if command -v file >/dev/null 2>&1 && file "$J" | grep -q 'dynamically linked'; then
    echo "FAIL: jevx links libc (it must not)"; exit 1
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2] want [$3]"; fi; }

M='Help! My payouts have been failing for 3 days.'
cat > "$T/three.jsonl" <<'JSONL'
{"status":200,"body":"{\"model\":\"typesafe/jev-1.13-20260917\",\"answers\":{\"u\":{\"type\":\"noul\",\"noul\":0.95},\"d\":{\"type\":\"choice\",\"choice\":\"billing\",\"probabilities\":{\"sales\":0,\"billing\":0.97,\"technical\":0.03},\"confidence\":0.96},\"f\":{\"type\":\"score\",\"score\":1.04,\"legend\":{\"0\":\"Calm\",\"1\":\"Frustrated\",\"2\":\"Very angry\"},\"probabilities\":{\"0\":0,\"1\":0.96,\"2\":0.04},\"confidence\":0.94}},\"usage\":{\"input_tokens\":372,\"output_tokens\":68,\"cost\":0.000015624},\"provider\":\"TypeSafe\"}"}
JSONL
Q=('u? Does this convey urgency?' 'd/ Which team? \| billing: Payments \| technical: Bugs \| sales' 'f# How frustrated? \| Calm \| Frustrated \| Very angry')

echo "version"
# feat.toml is at feats/jevx/ in zish and at the top of the jevx mirror.
toml=feats/jevx/feat.toml; [ -f "$toml" ] || toml=feat.toml
eq "--version matches feat.toml" "$("$J" --version)" "jevx $(sed -n 's/^version = "\(.*\)"/\1/p' "$toml")"

echo "request"
want='{"state":"Help! My payouts have been failing for 3 days.","model":"typesafe/jev-1.13","questions":{"u":{"type":"noul","instructions":"Does this convey urgency?"},"d":{"type":"choice","instructions":"Which team?","criteria":{"billing":"Payments","technical":"Bugs","sales":null}},"f":{"type":"score","instructions":"How frustrated?","criteria":["Calm","Frustrated","Very angry"]}}}'
eq "-n compiles the docs' example exactly" "$("$J" -n -s "$M" "${Q[@]}")" "$want"
eq "stdin is the state" "$(echo "$M" | "$J" -n "${Q[0]}" | cut -c1-60)" '{"state":"Help! My payouts have been failing for 3 days.","m'
eq "JSON stdin is sent as structure" "$(echo '{"a":1}' | "$J" -n '? is `a` one?' | cut -c1-17)" '{"state":{"a":1},'
eq "-t forces text" "$(echo '{"a":1}' | "$J" -n -t '? x' | cut -c1-21)" '{"state":"{\"a\":1}",'

echo "answers"
eq "one line per question, user's probability order" \
   "$("$J" --mock "$T/three.jsonl" -p -s "$M" "${Q[@]}")" \
   "$(printf 'u 0.95\nd billing 0.96 billing=0.97 technical=0.03 sales=0\nf 1.04 0.94 0=0 1=0.96 2=0.04')"
printf '{"status":200,"body":"{\\"model\\":\\"m\\",\\"answers\\":{\\"q1\\":{\\"type\\":\\"noul\\",\\"noul\\":0.3}},\\"usage\\":{\\"input_tokens\\":1,\\"output_tokens\\":1}}"}\n' > "$T/one.jsonl"
eq "a single question prints the bare value" "$("$J" --mock "$T/one.jsonl" -s x '? y')" "0.3"

echo "exit status"
"$J" --mock "$T/one.jsonl" -q -s x '?>.5 y'; eq "failed gate exits 1" "$?" 1
"$J" --mock "$T/one.jsonl" -q -s x '?<.5 y'; eq "passed gate exits 0" "$?" 0
"$J" --mock "$T/three.jsonl" -q -s x 'u?>.9 a' 'd/=billing~.99 b \| billing \| technical \| sales' 'f#>=1 c \| a \| b \| c'
eq "every gate must pass (confidence below ~.99)" "$?" 1
echo '{"status":422,"body":"{\"error\":{\"message\":\"questions.u: bad\"}}"}' > "$T/422.jsonl"
err=$("$J" --mock "$T/422.jsonl" -q -s x '?>.5 y' 2>&1); rc=$?
eq "HTTP error exits 2, not 1" "$rc" 2
eq "HTTP error message is surfaced" "$err" "jevx: HTTP 422: questions.u: bad"
printf '{"status":429,"body":"{}"}\n{"status":200,"body":"{\\"model\\":\\"m\\",\\"answers\\":{\\"q1\\":{\\"type\\":\\"noul\\",\\"noul\\":0.9}},\\"usage\\":{\\"input_tokens\\":1,\\"output_tokens\\":1}}"}\n' > "$T/429.jsonl"
eq "429 is retried" "$("$J" --mock "$T/429.jsonl" -s x '? y')" "0.9"
"$J" -n -s x 't/=zzz p \| a \| b' 2>/dev/null; eq "gate on an unoffered option is a usage error" "$?" 2
"$J" -n -s x '? is \0 ok' 2>/dev/null; eq "\\0 outside -l is a usage error" "$?" 2
"$J" -s x '? y' 2>/dev/null; eq "no key exits 2" "$?" 2

echo "hostile answers fail closed (exit 2, never a pass)"
bad_ans() { # name, answer-object JSON (escaped for the body string), question
    printf '{"status":200,"body":"{\\"answers\\":{\\"q1\\":%s}}"}\n' "$2" > "$T/bad.jsonl"
    "$J" --mock "$T/bad.jsonl" -q -s x "$3" 2>/dev/null; eq "$1" "$?" 2
}
bad_ans "noul with no value"               '{\\"type\\":\\"noul\\"}'                                     '?<.5 safe?'
bad_ans "noul out of [0,1]"                '{\\"type\\":\\"noul\\",\\"noul\\":7}'                    '?>.5 x'
bad_ans "choice with no choice"            '{\\"type\\":\\"choice\\",\\"confidence\\":1}'           '/!=bad x \| good \| bad'
bad_ans "choice not offered"               '{\\"type\\":\\"choice\\",\\"choice\\":\\"evil\\",\\"confidence\\":1}' '/!=bad x \| good \| bad'
bad_ans "choice with no confidence"        '{\\"type\\":\\"choice\\",\\"choice\\":\\"good\\"}'   '/=good x \| good \| bad'
bad_ans "score outside its levels"         '{\\"type\\":\\"score\\",\\"score\\":9,\\"confidence\\":1}' '#<1 x \| lo \| hi'
bad_ans "answer type differs from question" '{\\"type\\":\\"score\\",\\"score\\":0,\\"confidence\\":1}' '?<.5 x'
bad_ans "probability out of range"         '{\\"type\\":\\"choice\\",\\"choice\\":\\"good\\",\\"confidence\\":1,\\"probabilities\\":{\\"good\\":3}}' '/=good x \| good \| bad'
echo '{"status":-1,"body":"{}"}' > "$T/neg.jsonl"
"$J" --mock "$T/neg.jsonl" -q -s x '? y' 2>/dev/null; eq "mock status out of range is refused, not a crash" "$?" 2

echo "diagnostics"
big=$(head -c 6000 /dev/zero | tr '\0' x)
echo "{\"status\":500,\"body\":\"{\\\"error\\\":{\\\"message\\\":\\\"$big\\\"}}\"}" > "$T/big.jsonl"
n=$("$J" --mock "$T/big.jsonl" -s x '? y' 2>&1 | wc -c)
[ "$n" -gt 100 ] && [ "$n" -lt 700 ] && ok "a long error body is cut, not dropped ($n bytes)" || bad "long error body printed $n bytes"
printf '{"status":400,"body":"{\\"error\\":{\\"message\\":\\"\\u001b]0;pwned\\u0007\\"}}"}\n' > "$T/esc.jsonl"
"$J" --mock "$T/esc.jsonl" -s x '? y' 2>&1 | LC_ALL=C grep -q $'[\x1b\x07]' && bad "server bytes reach the terminal raw" || ok "control bytes in an error are neutralised"

echo "input bounds"
"$J" -n -s x '?>nan y' 2>/dev/null; eq "nan threshold refused" "$?" 2
"$J" -n -s x '?>1.5 y' 2>/dev/null; eq "noul threshold outside [0,1] refused" "$?" 2
"$J" -n -s x '/~2 y \| a \| b' 2>/dev/null; eq "confidence gate outside [0,1] refused" "$?" 2
"$J" -n -s x '#>4 y \| a \| b' 2>/dev/null; eq "score gate past the top level refused" "$?" 2
echo a | "$J" -n -l -b 18446744073709551615 '? x' 2>/dev/null; eq "-b overflow refused, not a crash" "$?" 2
echo a | "$J" -n -S - -l '? x' 2>/dev/null; eq "stdin is not read twice" "$?" 2
eq "a NUL in an item is data, not an item reference" "$(printf 'a\0b\n' | "$J" -n -l '? is \0 ok' | grep -o '"item":"[^"]*"')" '"item":"a\u0000b"'
printf 'x? a\0b\n' > "$T/nul.vim"; "$J" -n -s x -f "$T/nul.vim" 2>/dev/null; eq "a raw NUL in -f is refused" "$?" 2

echo "endpoint and key"
JEVX_ENDPOINT=http://example.com "$J" -s x '? y' 2>/dev/null; eq "plain-http endpoint refused" "$?" 2
echo sk-or-test > "$T/.zish/openrouter.key"
err=$(JEVX_ENDPOINT=https://example.invalid "$J" -s x '? y' 2>&1)
eq "custom endpoint never gets the OpenRouter key" "$err" 'jevx: no API key: JEVX_ENDPOINT needs $JEVX_API_KEY'
rm -f "$T/.zish/openrouter.key"

echo "transport (stub curl on PATH: what the real child is handed)"
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB/argv"
cat /dev/fd/3 > "$STUB/cfg"; cat /dev/fd/4 > "$STUB/body"
ls -A "$HOME/.zish" > "$STUB/dir"
[ -n "${STUB_EXIT:-}" ] && exit "$STUB_EXIT"
printf '{"model":"m","answers":{"q1":{"type":"noul","noul":0.8}},"usage":{"input_tokens":1,"output_tokens":1}}\n200'
SH
chmod +x "$T/stub/curl"
echo sk-or-stubkey > "$T/.zish/openrouter.key"; chmod 600 "$T/.zish/openrouter.key"
out=$(STUB="$T/stub" PATH="$T/stub:$PATH" "$J" -s hello '? y')
eq "answer comes back through the real transport" "$out" "0.8"
eq "the key reaches curl only on fd 3" "$(cat "$T/stub/cfg")" 'header = "Authorization: Bearer sk-or-stubkey"'
grep -q stubkey "$T/stub/argv" && bad "key in curl argv" || ok "key never in argv"
eq "the body reaches curl on fd 4" "$(cut -c1-17 "$T/stub/body")" '{"state":"hello",'
eq "nothing is written to ~/.zish during the request" "$(cat "$T/stub/dir")" "openrouter.key"
eq "curl's first argument is -q (no ~/.curlrc)" "$(head -1 "$T/stub/argv")" "-q"
grep -qx -- '=https' "$T/stub/argv" && ok "https-only (--proto =https)" || bad "no --proto =https"
eq "the URL is passed as --url's value" "$(grep -x -A1 -- --url "$T/stub/argv" | tail -1)" "https://openrouter.ai/api/alpha/decisions"
STUB="$T/stub" STUB_EXIT=28 PATH="$T/stub:$PATH" "$J" -q -s hello '?>.5 y' 2>/dev/null
eq "curl failing (e.g. timeout) exits 2, not a decision" "$?" 2
rm -f "$T/.zish/openrouter.key"

echo "--local: a Unix socket you own, in a directory only you can enter"
mksock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
mkdir -p "$T/run/jevx" && chmod 700 "$T/run" "$T/run/jevx" && mksock "$T/run/jevx/shingi.sock"
echo sk-or-stubkey > "$T/.zish/openrouter.key"; chmod 600 "$T/.zish/openrouter.key"
out=$(XDG_RUNTIME_DIR="$T/run" JEVX_API_KEY=sk-should-not-travel JEVX_ENDPOINT=https://example.invalid JEVX_MODEL=typesafe/jev-1.13 \
    STUB="$T/stub" PATH="$T/stub:$PATH" "$J" --local -s hello '? y')
eq "--local answers over the socket" "$out" "0.8"
eq "the socket is handed to curl" "$(grep -x -A1 -- --unix-socket "$T/stub/argv" | tail -1)" "$T/run/jevx/shingi.sock"
eq "--local ignores JEVX_ENDPOINT" "$(grep -x -A1 -- --url "$T/stub/argv" | tail -1)" "http://shingi/v1/systemone"
grep -qx -- '=http' "$T/stub/argv" && ok "plain http only inside the socket (--proto =http)" || bad "no --proto =http for --local"
eq "--local sends no key, not even JEVX_API_KEY" "$(cat "$T/stub/cfg")" ""
grep -q '"model":"shingi-27b"' "$T/stub/body" && ok "--local ignores JEVX_MODEL (it names a hosted model)" || bad "JEVX_MODEL leaked into --local"
out=$(JEVX_SOCKET="$T/run/jevx/shingi.sock" JEVX_BACKEND=shingi STUB="$T/stub" PATH="$T/stub:$PATH" "$J" -s hello '? y')
eq "JEVX_BACKEND=shingi is --local, JEVX_SOCKET names the socket" "$out" "0.8"
rm -f "$T/.zish/openrouter.key"
eq "-n --local compiles for shingi-27b without a server" "$(XDG_RUNTIME_DIR=/nonexistent "$J" -n --local -s x '? y' | grep -o '"model":"[^"]*"')" '"model":"shingi-27b"'
printf 'set local\n? y\n' > "$T/l.jevx"; eq "set local in a script is --local" "$(XDG_RUNTIME_DIR="$T/run" STUB="$T/stub" PATH="$T/stub:$PATH" "$J" -x "$T/l.jevx" hello)" "0.8"
refused() {  # refused NAME EXPECTED-REASON env...
    local name=$1 why=$2; shift 2
    local err; err=$(env "$@" STUB="$T/stub" PATH="$T/stub:$PATH" "$J" --local -s x '? y' 2>&1); local rc=$?
    case $rc:$err in 2:*"$why"*) ok "$name" ;; *) bad "$name (rc=$rc: $err)" ;; esac
}
: > "$T/stub/argv"
refused "no socket: refused, nothing sent" "does not exist" XDG_RUNTIME_DIR="$T/nowhere"
[ -s "$T/stub/argv" ] && bad "curl ran for a refused --local" || ok "a refused --local never starts curl"
refused "no XDG_RUNTIME_DIR and no JEVX_SOCKET: refused" "no socket" -u XDG_RUNTIME_DIR -u JEVX_SOCKET
: > "$T/run/jevx/file"; refused "a regular file is not a socket" "is not a socket" JEVX_SOCKET="$T/run/jevx/file"
ln -s "$T/run/jevx/shingi.sock" "$T/run/jevx/link.sock"; refused "a symlink to a good socket is refused" "is a symlink" JEVX_SOCKET="$T/run/jevx/link.sock"
refused "a relative socket path is refused" "absolute" JEVX_SOCKET=jevx/shingi.sock
chmod 755 "$T/run/jevx"; refused "a directory others can enter is refused" "open to others" XDG_RUNTIME_DIR="$T/run"; chmod 700 "$T/run/jevx"
mkdir -p "$T/real" && chmod 700 "$T/real" && mksock "$T/real/s.sock" && ln -s "$T/real" "$T/run/linkdir"
refused "a socket reached through a symlinked directory is refused" "is not a directory" JEVX_SOCKET="$T/run/linkdir/s.sock"

echo "key file"
echo sk-or-x > "$T/.zish/openrouter.key"; chmod 644 "$T/.zish/openrouter.key"
err=$("$J" -s x '? y' 2>&1); rc=$?
eq "a group/world-readable key file is refused" "$rc" 2
case "$err" in *"readable by others"*) ok "and says why" ;; *) bad "refusal message: $err" ;; esac
rm -f "$T/.zish/openrouter.key"; echo sk-or-x > "$T/real.key"; chmod 600 "$T/real.key"
ln -s "$T/real.key" "$T/.zish/openrouter.key"
"$J" -s x '? y' 2>/dev/null; eq "a symlinked key file is refused" "$?" 2
rm -f "$T/.zish/openrouter.key" "$T/real.key"

echo "scripts (.jevx)"
mkdir -p "$T/bin"; ln -sf "$J" "$T/bin/jevx"
cat > "$T/route.jevx" <<'JEVX'
#!/usr/bin/env jevx
" route a ticket
set export
team/ Which team? \| billing: payments \| sales
JEVX
chmod +x "$T/route.jevx"
cat > "$T/route.jsonl" <<'JSONL'
{"status":200,"body":"{\"model\":\"m\",\"answers\":{\"team\":{\"type\":\"choice\",\"choice\":\"billing\",\"probabilities\":{\"billing\":0.9,\"sales\":0.1},\"confidence\":0.8}},\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"}
JSONL
eq "a #! script runs; its args are the state" \
   "$(PATH="$T/bin:$PATH" "$T/route.jevx" -n payouts are failing | cut -c1-30)" '{"state":"payouts are failing"'
out=$(PATH="$T/bin:$PATH" "$T/route.jevx" --mock "$T/route.jsonl" payouts failing)
eq "set export prints eval-able assignments" "$out" "$(printf "jev_team='billing'\njev_team_conf='0.8'")"
eval "$out"; eq "and eval sets them" "$jev_team" billing
eq "-x FILE is the same as a .jevx first argument" \
   "$("$J" -x "$T/route.jevx" -n hi | cut -c1-12)" '{"state":"hi'
eq "stdin is the state when no words are given" "$(echo from-stdin | "$J" "$T/route.jevx" -n | cut -c1-21)" '{"state":"from-stdin"'
"$J" "$T/route.jevx" -n -s a word 2>/dev/null; eq "args and -s together are refused" "$?" 2
"$J" -n "$T/route.jevx" 2>/dev/null; eq "a .jevx not first is refused, not read as a question" "$?" 2
printf 'set line\n? x\n' > "$T/typo.jevx"; "$J" "$T/typo.jevx" -n x 2>/dev/null; eq "unknown set option refused" "$?" 2
"$J" -n -e -s x 'a-b? y' 'a_b? z' 2>/dev/null; eq "-e refuses two keys on one variable" "$?" 2
"$J" -n -E 'bad-pfx' -s x '? y' 2>/dev/null; eq "-E needs an identifier prefix" "$?" 2
echo a | "$J" -n -l -e '? x' 2>/dev/null; eq "-e with -l refused" "$?" 2

echo "standalone key path"
mkdir -p "$T/.config/jevx"; echo sk-or-cfgkey > "$T/.config/jevx/openrouter.key"; chmod 600 "$T/.config/jevx/openrouter.key"
STUB="$T/stub" PATH="$T/stub:$PATH" "$J" -s hi '? y' >/dev/null
eq "the key is found under ~/.config/jevx without ~/.zish" "$(cat "$T/stub/cfg")" 'header = "Authorization: Bearer sk-or-cfgkey"'
echo sk-or-zishkey > "$T/.zish/openrouter.key"; chmod 600 "$T/.zish/openrouter.key"
STUB="$T/stub" PATH="$T/stub:$PATH" "$J" -s hi '? y' >/dev/null
eq "~/.zish wins when both exist" "$(cat "$T/stub/cfg")" 'header = "Authorization: Bearer sk-or-zishkey"'
rm -rf "$T/.config" "$T/.zish/openrouter.key"

echo "lines"
printf 'apple\n\nvertex\nbanana\n' > "$T/words"
want='{"state":"","model":"typesafe/jev-1.13","questions":{"f.0":{"type":"noul","instructions":{"item":"apple","question":"Is `item` a fruit?"}},"f.1":{"type":"noul","instructions":{"item":"vertex","question":"Is `item` a fruit?"}},"f.2":{"type":"noul","instructions":{"item":"banana","question":"Is `item` a fruit?"}}}}'
eq "-l asks per non-empty line, the line inside its question" "$("$J" -n -l 'f? Is \0 a fruit?' < "$T/words")" "$want"
eq "-b splits items into requests" "$("$J" -n -l -b 2 'f? x' < "$T/words" | wc -l)" 2
printf '{"status":200,"body":"{\\"model\\":\\"m\\",\\"answers\\":{\\"f.0\\":{\\"type\\":\\"noul\\",\\"noul\\":0.99},\\"f.1\\":{\\"type\\":\\"noul\\",\\"noul\\":0.01},\\"f.2\\":{\\"type\\":\\"noul\\",\\"noul\\":0.98}},\\"usage\\":{\\"input_tokens\\":1,\\"output_tokens\\":1}}"}\n' > "$T/fruit.jsonl"
eq "-l with a gate prints passing lines" "$("$J" --mock "$T/fruit.jsonl" -l 'f?>.5 Is \0 a fruit?' < "$T/words")" "$(printf 'apple\nbanana')"
eq "-l -v prints failing lines" "$("$J" --mock "$T/fruit.jsonl" -l -v 'f?>.5 Is \0 a fruit?' < "$T/words")" "vertex"
"$J" -n -l -v 'f? x' < "$T/words" 2>/dev/null; eq "-v without a gate is a usage error" "$?" 2
eq "-l without a gate prefixes answers" "$("$J" --mock "$T/fruit.jsonl" -l 'f? x' < "$T/words" | head -1)" "$(printf '0.99\tapple')"

echo "-0 and size-planned batches"
eq "-0 items may span lines" \
   "$(printf 'fn a() {\n  x;\n}\0fn b() {}\0' | "$J" -n -0 'q? Does \0 run a command?' | grep -o '"item":"[^"]*"' | head -1)" '"item":"fn a() {\n  x;\n}"'
printf '{"status":200,"body":"{\\"model\\":\\"m\\",\\"answers\\":{\\"f.0\\":{\\"type\\":\\"noul\\",\\"noul\\":0.9},\\"f.1\\":{\\"type\\":\\"noul\\",\\"noul\\":0.1}},\\"usage\\":{\\"input_tokens\\":1,\\"output_tokens\\":1}}"}\n' > "$T/z.jsonl"
eq "-0 output is NUL-terminated items" \
   "$(printf 'apple\npie\0bolt\0' | "$J" --mock "$T/z.jsonl" -0 'f?>.5 food? \0' | od -An -c | tr -s ' ' | sed 's/^ //')" 'a p p l e \n p i e \0'
big=$(head -c 3000 /dev/zero | tr '\0' x)
n=$(for i in $(seq 60); do printf '%s\0' "$big"; done | "$J" -n -0 'q? \0' | wc -l)
[ "$n" -ge 2 ] && ok "requests are packed by size, not one oversized request ($n requests)" || bad "60 x 3 KB items went out as $n request(s)"
eq "-b still caps items per request" "$(for i in $(seq 6); do printf 'x\0'; done | "$J" -n -0 -b 2 'q? \0' | wc -l)" 3
head -c 70000 /dev/zero | tr '\0' x | "$J" -n -0 'q? big \0' 2>/dev/null; eq "an item too big to fit alone is a usage error" "$?" 2
head -c 200000 /dev/zero | tr '\0' x | "$J" -n 'q? big' 2>/dev/null; eq "an oversized single request is refused before sending" "$?" 2

echo "question file"
cat > "$T/q.vim" <<'EOF'
" support routing
team/ Which team
    \ handles this ticket?
  \| billing: Payments
  \| sales
EOF
eq "-f: \" comments, \\ continuation" "$("$J" -n -s x -f "$T/q.vim")" \
   '{"state":"x","model":"typesafe/jev-1.13","questions":{"team":{"type":"choice","instructions":"Which team handles this ticket?","criteria":{"billing":"Payments","sales":null}}}}'

echo "hygiene"
ls "$T/.zish" | grep -qE '^\.jevx?-' && bad "temp files left in ~/.zish" || ok "no temp files left in ~/.zish"
"$J" --mock "$T/three.jsonl" -s "$M" "${Q[@]}" | head -c1 >/dev/null; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || [ "$rc" = 141 ] && ok "closed stdout does not hang ($rc)" || bad "closed stdout exit $rc"

echo; echo "jevx: $pass passed, $fail failed"
[ "$fail" = 0 ]
