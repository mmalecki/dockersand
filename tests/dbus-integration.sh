#!/usr/bin/env bash
# Optional live test: bash tests/dbus-integration.sh <agents-based-image>
set -euo pipefail

image="${1:-agents}"
launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d /tmp/dockersand-dbus-live.XXXXXX)"
daemon_pid=""
cleanup() {
  if [[ -n "$daemon_pid" ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/project"
# Exercise Docker CSV parsing with a real socket whose path has punctuation.
socket="$fixture/bus with,colon:and%quote\".sock"
address="unix:path=$fixture/bus%20with%2ccolon%3aand%25quote%22.sock"
dbus-daemon --session --nofork --nopidfile --address="$address" >"$fixture/daemon.log" 2>&1 &
daemon_pid=$!
for ((attempt = 0; attempt < 40; attempt++)); do
  [[ ! -S "$socket" ]] || break
  sleep 0.05
done
[[ -S "$socket" ]] || { cat "$fixture/daemon.log" >&2; exit 1; }

export DBUS_SESSION_BUS_ADDRESS="$address" DOCKERSAND_DBUS=1 DOCKERSAND_GIT_STRATEGY=mount
unset DOCKERSAND_EGRESS DOCKERSAND_SSH DOCKERSAND_SESSION_NAME
host_id="$(dbus-send --session --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.GetId | sed -n 's/^ *string "\(.*\)"$/\1/p')"
cd "$fixture/project"
sandbox_id="$(DOCKERSAND_ENTRYPOINT=dbus-send "$launcher" "$image" \
  --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetId \
  | sed -n 's/^ *string "\(.*\)"$/\1/p')"
[[ -n "$host_id" && "$sandbox_id" == "$host_id" ]]
echo 'PASS: sandbox authenticates to the same private bus as the host'
DOCKERSAND_ENTRYPOINT=bash "$launcher" "$image" -c 'set -e; notify-send --version; secret-tool lookup --help >/dev/null'
echo 'PASS: notification and Secret Service clients are available'
