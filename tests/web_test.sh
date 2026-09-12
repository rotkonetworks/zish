#!/usr/bin/env bash
# web tests — the search/fetch feat. Network is `env curl`, so a stub `curl`
# first on PATH makes every case hermetic (no socket is opened) and lets the
# stub log its argv, which is how the query encoding and the backend template
# are checked. What is pinned is the observable contract of each verb: fetch
# strips tags / decodes entities / honours ZISH_WEB_MAX and its truncation
# notice / treats a non-zero curl exit as a failure (exit 1, no stdout) rather
# than an empty page; search parses DuckDuckGo's markup when no backend is
# configured and fails loudly when the markup yields nothing; usage errors exit
# 2; and a dead stdout reader kills the process with SIGPIPE (141), not a quiet 0.
set -u
cd "$(dirname "$0")/.."

T=$(mktemp -d /tmp/web-test-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/stub"

FEAT_BIN=${FEAT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/share/zish/feats/standard}
cp "$FEAT_BIN/web/bin/web" "$T/web" || { echo "FAIL: $FEAT_BIN/web not built — run: zig build -Dfeats=all"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# ---- stub curl: dispatches on the URL, logs its argv, opens no socket -------
# The feat execs `/usr/bin/env curl …`, so `curl` is found through PATH (the
# stub dir must come first) and the rest of the system is untouched.
STUB_LOG="$T/curl.log"; : > "$STUB_LOG"; export STUB_LOG
gone() { : > "$STUB_LOG"; }   # forget the stub log between cases

cat > "$T/stub/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG:?}"
for a in "$@"; do url="$a"; done
case "$url" in
  *big*)        yes 'lorem ipsum dolor sit amet consectetur adipiscing elit' | head -c 131072 ;;
  # Non-zero exit after emitting a partial body: what curl does on a timeout,
  # a reset connection, or DNS failure mid-transfer. The feat must not read
  # those bytes as a complete (if short) page.
  *fail*)       printf '<html><body><h1>Partial</h1><p>cut off mid' ; exit 7 ;;
  *duckduckgo*) cat "${STUB_BODY:?}" ;;
  *)            printf '<html><body><h1>Title</h1><p>Hello &amp; goodbye &mdash; ok</p><script>var x=1;</script></body></html>\n' ;;
esac
exit 0
SH
chmod +x "$T/stub/curl"

# a DuckDuckGo-shaped page: result__a anchors (one behind an uddg= redirect),
# each followed by a result__snippet
cat > "$T/ddg.html" <<'HTML'
<html><body>
<div class="result results_links">
  <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=ab">Example <b>Title</b></a>
  <a class="result__snippet" href="http://x">A snippet about it.</a>
</div>
<div class="result results_links">
  <a rel="nofollow" class="result__a" href="https://other.example/b">Other &amp; Co</a>
  <a class="result__snippet" href="http://y">Another snippet.</a>
</div>
</body></html>
HTML
STUB_BODY="$T/ddg.html"; export STUB_BODY

W() { PATH="$T/stub:/usr/bin:/bin" HOME="$T/home" "$T/web" "$@"; }

PAGE_TEXT=$(printf 'Title\nHello & goodbye — ok')

echo "== usage (exit 2, nothing fetched) =="
o=$(W 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "no verb -> exit 2" || bad "no verb exit $rc"
case "$o" in *"usage: web search <query> | web fetch <url>"*) ok "no verb prints the usage line" ;; *) bad "no usage: $o" ;; esac
gone
W fetch >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "fetch without a URL -> exit 2" || bad "fetch without URL exit $rc"
W search >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "search without a query -> exit 2" || bad "search without query exit $rc"
[ ! -s "$STUB_LOG" ] && ok "usage errors fetch nothing" || bad "usage error still ran curl: $(cat "$STUB_LOG")"

echo "== fetch: readable text, not markup =="
o=$(W fetch http://stub/page); rc=$?
[ "$rc" -eq 0 ] && ok "fetch exits 0" || bad "fetch exit $rc"
[ "$o" = "$PAGE_TEXT" ] && ok "tags stripped, <script> dropped, entities decoded" || bad "fetch text: <$o>"
o=$(W get http://stub/page)
[ "$o" = "$PAGE_TEXT" ] && ok "'web get' is the same fetcher" || bad "get: <$o>"

echo "== fetch: ZISH_WEB_MAX bounds the output =="
o=$(ZISH_WEB_MAX=10 W fetch http://stub/page); rc=$?
[ "$rc" -eq 0 ] && ok "bounded fetch still exits 0" || bad "bounded fetch exit $rc"
case "$o" in *"[truncated"*) ok "over the bound -> truncation notice" ;; *) bad "no notice: <$o>" ;; esac
case "$o" in *goodbye*) bad "text past the bound leaked: <$o>" ;; *) ok "nothing past the bound is emitted" ;; esac

echo "== fetch: a non-zero curl is a failure, not an empty page =="
# curl exits non-zero on a timeout, a refused connection, a DNS failure — and
# may already have written part of the body. Collecting the child's status and
# discarding it made those bytes read as a complete, successful page (exit 0),
# indistinguishable from a genuinely empty document. Fail closed: exit 1, no
# stdout at all, and the reason on stderr.
gone
o=$(W fetch http://stub/fail 2>"$T/fail.err"); rc=$?
[ "$rc" -eq 1 ] && ok "curl exits non-zero -> fetch exits 1" || bad "failed fetch exit $rc: <$o>"
[ -z "$o" ] && ok "failed fetch emits nothing on stdout (partial body dropped)" \
    || bad "failed fetch printed a partial page: <$o>"
case "$(cat "$T/fail.err")" in
    *"fetch failed"*) ok "failed fetch says why on stderr" ;;
    *) bad "no failure diagnostic: <$(cat "$T/fail.err")>" ;;
esac

echo "== search: DuckDuckGo markup parsed (default backend) =="
gone
o=$(W search zish shell); rc=$?
[ "$rc" -eq 0 ] && ok "search exits 0" || bad "search exit $rc: $o"
case "$o" in *"1. Example Title"*) ok "title parsed, inline tags stripped" ;; *) bad "no first title: <$o>" ;; esac
case "$o" in *"https://example.com/a"*) ok "uddg= redirect unwrapped to the real URL" ;; *) bad "url not decoded: <$o>" ;; esac
case "$o" in *"A snippet about it."*) ok "snippet parsed" ;; *) bad "no snippet: <$o>" ;; esac
case "$o" in *"2. Other & Co"*) ok "second result numbered, entities decoded" ;; *) bad "no second result: <$o>" ;; esac
grep -q 'html.duckduckgo.com/html/?q=zish%20shell' "$STUB_LOG" \
    && ok "multi-word query percent-encoded into the search URL" \
    || bad "search URL: $(cat "$STUB_LOG")"

gone
W s hi >/dev/null 2>&1
grep -q 'html.duckduckgo.com/html/?q=hi' "$STUB_LOG" && ok "'s' is an alias for search" || bad "s alias: $(cat "$STUB_LOG")"

gone
o=$(W zish 2>&1 | head -1)
case "$o" in *"Example Title"*) ok "bare 'web <query>' searches (verb is the query)" ;; *) bad "bare search: <$o>" ;; esac

echo "== search: custom backend template, and empty results =="
gone
o=$(ZISH_WEB_SEARCH='http://stub/search?q={q}&format=json' W search 'a/b c' 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "custom backend exits 0" || bad "custom backend exit $rc: $o"
grep -q 'http://stub/search?q=a%2Fb%20c&format=json' "$STUB_LOG" \
    && ok "template filled with the percent-encoded query" \
    || bad "backend URL: $(cat "$STUB_LOG")"

printf '<html><body><p>nothing to parse here</p></body></html>\n' > "$T/none.html"
o=$(STUB_BODY="$T/none.html" W search zish 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "no parseable results -> exit 1" || bad "no-results exit $rc: $o"
case "$o" in *"no results parsed"*) ok "no-results says why on stderr" ;; *) bad "diagnostic missing: <$o>" ;; esac

echo "== SIGPIPE: a closed stdout kills web (141), not a quiet 0 =="
# A filter must die when the reader of its stdout is gone. `head -c1` takes one
# byte and exits while web still has 128 KiB of page text to write, so the next
# write must take SIGPIPE — the traditional disposition, which full
# `std.process.Init` replaces with a no-op handler and `feat.restoreSigpipe()`
# puts back. Red without it (EPIPE swallowed, exit 0), green (141) with it.
ZISH_WEB_MAX=1000000 W fetch http://stub/big 2>/dev/null | head -c1 >/dev/null
rc=${PIPESTATUS[0]}
[ "$rc" -eq 141 ] && ok "web fetch, stdout reader gone -> exit 141 (SIGPIPE)" \
    || bad "web fetch over a closed stdout -> exit $rc (want 141)"

echo
total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf '\033[32mALL GREEN\033[0m — %d passed\n' "$pass"; exit 0
fi
printf '\033[31mRED\033[0m — %d/%d failed\n' "$fail" "$total"; exit 1
