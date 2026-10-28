#!/usr/bin/env bash
# Run inside the chromium image: chrome-devtools-mcp must drive a headless, sandboxed Chromium.
set -euo pipefail

fixture="$(mktemp -d)"
cleanup() {
  kill "${COPROC_PID:-}" "${server_pid:-}" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; cat "$fixture"/*.log >&2 2>/dev/null; exit 1; }

printf '<title>dockersand</title><p id="proof"></p><script>proof.textContent = "rendered-" + "by-chromium"</script>\n' \
  >"$fixture/index.html"
python3 -u -m http.server --bind 127.0.0.1 --directory "$fixture" 0 >"$fixture/server.log" 2>&1 &
server_pid=$!
for _ in {1..50}; do
  port="$(grep -om1 'port [0-9]*' "$fixture/server.log" | cut -d' ' -f2)" && break
  sleep 0.1
done
[[ -n "${port:-}" ]] || fail 'HTTP server did not start'

# Chromium reports a missing sandbox here, not through the MCP server.
dom="$(chromium --headless --dump-dom "http://127.0.0.1:$port/" 2>"$fixture/chromium.log")" ||
  fail 'Chromium did not start'
grep -q rendered-by-chromium <<<"$dom" || fail "Chromium did not render the page: $dom"
echo 'PASS: headless Chromium renders a page'

# --isolated uses a temporary profile; everything else comes from the image's config file.
coproc chrome-devtools-mcp --isolated 2>"$fixture/mcp.log"
id=0
rpc() {
  id=$((id + 1))
  jq -cn --argjson id "$id" --arg method "$1" --argjson params "$2" \
    '{jsonrpc: "2.0", id: $id, method: $method, params: $params}' >&"${COPROC[1]}"
  local line
  while read -r -t 60 line <&"${COPROC[0]}"; do
    jq -e --argjson id "$id" '.id == $id' <<<"$line" >/dev/null || continue
    jq -e '.error or .result.isError' <<<"$line" >/dev/null && fail "$1: $line"
    jq -r '.result.content[]? | select(.type == "text") | .text' <<<"$line"
    return
  done
  fail "no response to $1"
}

rpc initialize '{"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}' >/dev/null
echo '{"jsonrpc": "2.0", "method": "notifications/initialized"}' >&"${COPROC[1]}"

pages="$(rpc tools/call "$(jq -cn --arg url "http://127.0.0.1:$port/" '{name: "new_page", arguments: {url: $url}}')")"
page="$(grep -om1 '^[0-9]*: dockersand ' <<<"$pages" | cut -d: -f1)" || fail "page did not open: $pages"
result="$(rpc tools/call "$(jq -cn --argjson page "$page" '{name: "evaluate_script", arguments: {pageId: $page,
  function: "() => [document.getElementById(\"proof\").textContent, navigator.userAgent]"}}')")"
grep -q 'rendered-by-chromium' <<<"$result" || fail "page did not render: $result"
grep -q 'HeadlessChrome' <<<"$result" || fail "browser is not headless: $result"
echo 'PASS: chrome-devtools-mcp loads and scripts a page in headless Chromium'

pid="$(pgrep -u "$(id -u)" -of -- --remote-debugging-pipe)" || fail 'no browser process found'
[[ "$(readlink "/proc/$pid/exe")" == /usr/lib/chromium/chromium ]] || fail "unexpected browser: $(readlink "/proc/$pid/exe")"
# Without --no-sandbox, Chromium refuses to start unless its sandbox works.
! tr '\0' '\n' <"/proc/$pid/cmdline" | grep -qx -- --no-sandbox || fail 'Chromium runs without its sandbox'
echo 'PASS: Debian Chromium with its sandbox enabled'
