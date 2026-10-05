#!/usr/bin/env bash
set -euo pipefail

launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d /tmp/dockersand-dbus.XXXXXX)"
daemon_pids=()
cleanup() {
  for pid in "${daemon_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/bin" "$fixture/project" "$fixture/runtime"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export XDG_STATE_HOME="$fixture/state" DOCKERSAND_ARGS_FILE="$fixture/args"
unset DOCKERSAND_DBUS DOCKERSAND_SSH DOCKERSAND_EGRESS DOCKERSAND_SESSION_NAME
unset DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS XDG_RUNTIME_DIR
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

fail() { echo "FAIL: $*" >&2; exit 1; }

start_bus() {
  local attempt pid
  dbus-daemon --session --nofork --nopidfile --address="$1" >"$fixture/daemon.log" 2>&1 &
  pid=$!
  daemon_pids+=("$pid")
  for ((attempt = 0; attempt < 40; attempt++)); do
    [[ ! -S "$2" ]] || return 0
    kill -0 "$pid" 2>/dev/null || { cat "$fixture/daemon.log" >&2; fail 'D-Bus daemon exited'; }
    sleep 0.05
  done
  fail 'D-Bus daemon did not create its socket'
}

socket="$fixture/runtime/bus"
start_bus "unix:path=$socket" "$socket"
special_socket="$fixture/bus with,colon:and%quote\".sock"
special_address="unix:path=$fixture/bus%20with%2ccolon%3aand%25quote%22.sock"
start_bus "$special_address" "$special_socket"

cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" >"$DOCKERSAND_ARGS_FILE"
  exit 0
fi
exit 1
EOF
chmod +x "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"

run_sandbox() {
  (cd "$fixture/project" && DOCKERSAND_GIT_STRATEGY=mount env "$@" "$launcher" test env) \
    2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail 'launcher failed'; }
  mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
}

expect_failure() {
  : >"$DOCKERSAND_ARGS_FILE"
  if (cd "$fixture/project" && DOCKERSAND_GIT_STRATEGY=mount env DOCKERSAND_DBUS=1 "$@" "$launcher" test env) \
    2>"$fixture/stderr"; then
    fail 'invalid bus unexpectedly accepted'
  fi
  [[ ! -s "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called for an invalid bus'
  local error
  error="$(<"$fixture/stderr")"
  [[ "$error" == *'session bus filesystem socket'* || "$error" == *'invalid filesystem path'* ]] || fail 'missing diagnostic'
}

assert_arg() {
  local arg
  for arg in "${args[@]}"; do
    [[ "$arg" != "$1" ]] || return 0
  done
  fail "missing argument: $1"
}

assert_forwarded() {
  assert_arg "type=bind,\"src=$1\",dst=/tmp/dbus-session.sock,readonly"
  assert_arg DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-session.sock
  assert_arg --runtime=runsc
  assert_arg no-new-privileges
  local arg
  for arg in "${args[@]}"; do
    [[ "$arg" != DBUS_SYSTEM_BUS_ADDRESS=* ]] || fail 'system bus was forwarded'
    [[ "$arg" != "$fixture/runtime:"* ]] || fail 'runtime directory was forwarded'
  done
}

for value in '' 0; do
  run_sandbox "DOCKERSAND_DBUS=$value" "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/irrelevant/system-bus "XDG_RUNTIME_DIR=$fixture/runtime"
  for arg in "${args[@]}"; do
    [[ "$arg" != DBUS_*=* && "$arg" != *dbus-session.sock* ]] || fail 'D-Bus forwarded without opt-in'
  done
done
run_sandbox DBUS_SESSION_BUS_ADDRESS='not-an-address'
echo 'PASS: forwarding is opt-in, including when an invalid host address is present'

run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket"
assert_forwarded "$socket"
echo 'PASS: explicit session socket'

run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=unix:guid=0123456789abcdef,path=$socket"
assert_forwarded "$socket"
echo 'PASS: path option after GUID'

run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=$special_address"
assert_forwarded "$fixture/bus with,colon:and%quote\"\".sock"
echo 'PASS: percent decoding and CSV escaping of socket paths'

run_sandbox DOCKERSAND_DBUS=1 \
  "DBUS_SESSION_BUS_ADDRESS=tcp:host=localhost,port=1;unix:abstract=missing;unix:path=$fixture/missing;unix:path=$socket"
assert_forwarded "$socket"
echo 'PASS: select a usable filesystem socket from an address list'

for address in '' unset; do
  if [[ "$address" == unset ]]; then
    run_sandbox DOCKERSAND_DBUS=1 "XDG_RUNTIME_DIR=$fixture/runtime"
  else
    run_sandbox DOCKERSAND_DBUS=1 DBUS_SESSION_BUS_ADDRESS= "XDG_RUNTIME_DIR=$fixture/runtime"
  fi
  assert_forwarded "$socket"
done
echo 'PASS: runtime directory fallback for unset and empty addresses'

touch "$fixture/regular-file"
for address in \
  "unix:path=$fixture/missing" "unix:path=$fixture/regular-file" "unix:path=$fixture/runtime" \
  'unix:abstract=unmountable' 'tcp:host=localhost,port=1' 'autolaunch:' \
  'unix:path=relative.sock' 'unix:path=/tmp/bad%GG' 'unix:path=/tmp/bad%0' \
  'unix:path=/tmp/bad%' 'unix:path=/tmp/bad%00' 'unix:path=/tmp/raw space' \
  'unix:path=/tmp/raw\backslash'; do
  expect_failure "DBUS_SESSION_BUS_ADDRESS=$address" "XDG_RUNTIME_DIR=$fixture/runtime"
done
echo 'PASS: invalid, missing and unsupported explicit addresses fail without fallback'

expect_failure "XDG_RUNTIME_DIR=$fixture/missing-runtime"
echo 'PASS: missing fallback socket fails before Docker is launched'

run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
  DOCKERSAND_SSH=1 "SSH_AUTH_SOCK=$fixture/ssh-agent.sock" DBUS_SYSTEM_BUS_ADDRESS=unix:path=/irrelevant/system-bus
assert_forwarded "$socket"
assert_arg "$fixture/ssh-agent.sock:/tmp/ssh-agent.sock"
echo 'PASS: D-Bus and SSH forwarding work together'

git -C "$fixture/project" init -q
git -C "$fixture/project" -c user.name=Fixture -c user.email=fixture@example.test \
  commit -q --allow-empty -m initial
run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
  DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION_NAME=dbus
assert_forwarded "$socket"
echo 'PASS: forwarding works with the clone strategy'
