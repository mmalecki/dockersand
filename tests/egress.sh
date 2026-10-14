#!/usr/bin/env bash
set -euo pipefail

launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/project" "$fixture/home"
export HOME="$fixture/home" XDG_STATE_HOME="$fixture/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export DOCKERSAND_ARGS_FILE="$fixture/args"
export DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_EGRESS=1
unset DOCKERSAND_DBUS DOCKERSAND_SSH DOCKERSAND_GH DOCKERSAND_GCLOUD
unset DOCKERSAND_DIND DOCKERSAND_SESSION_NAME DOCKERSAND_ENTRYPOINT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
export MOCK_PROXY_RUNNING=true MOCK_PROXY_IP=172.20.0.2
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  'inspect -f')
    if [[ "$3" == '{{.State.Running}}' ]]; then
      printf '%s\n' "$MOCK_PROXY_RUNNING"
    else
      printf '%s\n' "$MOCK_PROXY_IP"
    fi
    ;;
  run\ *) printf '%s\0' "$@" >"$DOCKERSAND_ARGS_FILE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/docker"
export PATH="$fixture/bin:$PATH"
cd "$fixture/project"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  rm -f "$DOCKERSAND_ARGS_FILE"
  if "$launcher" alpine >"$fixture/stdout" 2>"$fixture/stderr"; then
    fail 'unavailable proxy accepted'
  fi
  [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called after failed validation'
  [[ -s "$fixture/stderr" ]] || fail 'no diagnostic'
}

MOCK_PROXY_RUNNING=false
expect_failure
MOCK_PROXY_RUNNING=true
MOCK_PROXY_IP=''
expect_failure
echo 'PASS: filtered launch requires a running, attached proxy'

MOCK_PROXY_IP=172.20.0.2
"$launcher" alpine 2>"$fixture/stderr"
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
for expected in dockersand-internal HTTP_PROXY=http://172.20.0.2:3128 HTTPS_PROXY=http://172.20.0.2:3128; do
  found=0
  for arg in "${args[@]}"; do [[ "$arg" != "$expected" ]] || found=1; done
  (( found )) || fail "missing argument: $expected"
done
echo 'PASS: filtered sandbox launches with the proxy configured'

MOCK_PROXY_RUNNING=false DOCKERSAND_EGRESS=0 "$launcher" alpine 2>"$fixture/stderr"
echo 'PASS: ordinary launches do not require the proxy'
