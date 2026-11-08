#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

daemon_pids=()
cleanup() {
  for pid in "${daemon_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$fixture"
}
mkdir -p "$repo" "$fixture/runtime"
unset DBUS_SESSION_BUS_ADDRESS DBUS_SYSTEM_BUS_ADDRESS XDG_RUNTIME_DIR

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

install_fake_docker

expect_failure() {
  expect_rejected DOCKERSAND_DBUS=1 "$@" run test env
  local error
  error="$(<"$fixture/stderr")"
  [[ "$error" == *'session bus filesystem socket'* || "$error" == *'invalid filesystem path'* ]] || fail 'missing diagnostic'
}

assert_forwarded() {
  assert_arg "type=bind,\"src=$1\",\"dst=/run/dockersand/dbus-session.sock\",readonly"
  assert_arg DBUS_SESSION_BUS_ADDRESS=unix:path=/run/dockersand/dbus-session.sock
  assert_arg --runtime=runsc
  assert_arg no-new-privileges
  assert_no_arg_matching 'DBUS_SYSTEM_BUS_ADDRESS=*'
  assert_no_arg_matching "*src=$fixture/runtime\"*"
  assert_no_arg -v
}

for value in '' 0; do
  run_sandbox "DOCKERSAND_DBUS=$value" "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/irrelevant/system-bus "XDG_RUNTIME_DIR=$fixture/runtime"
  assert_no_arg_matching 'DBUS_*=*'
  assert_no_arg_matching '*dbus-session.sock*'
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
assert_arg "type=bind,\"src=$fixture/ssh-agent.sock\",\"dst=/run/dockersand/ssh-agent.sock\""
echo 'PASS: D-Bus and SSH forwarding work together'

cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/forwarding-args"
run_sandbox DOCKERSAND_DBUS=0 DOCKERSAND_SSH=0 "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
  "SSH_AUTH_SOCK=$fixture/ssh-agent.sock" --ssh --dbus -- test env
cmp -s "$fixture/forwarding-args" "$FAKE_DOCKER_ARGS_FILE" || fail 'forwarding switches differ from environment opt-ins'
echo 'PASS: --ssh and --dbus combine and override environment opt-outs'

make_repo "$repo"
run_sandbox DOCKERSAND_DBUS=1 "DBUS_SESSION_BUS_ADDRESS=unix:path=$socket" \
  DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=dbus
assert_forwarded "$socket"
echo 'PASS: forwarding works with the clone strategy'
