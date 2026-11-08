# shellcheck shell=bash
# Shared fixture, fake docker and assertions for the launcher test suites.
# Source it right after `set -euo pipefail`.

launcher="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dockersand"
# Directly under /tmp, as D-Bus socket paths have a short length limit
fixture="$(mktemp -d /tmp/dockersand-test.XXXXXX)"
# A suite with more to clean up redefines this
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT
mkdir -p "$fixture/bin"
export PATH="$fixture/bin:$PATH"

# The project run_sandbox launches from; suites can point it elsewhere
repo="$fixture/repo"

# Hermetic: the developer's own settings must not change what's tested
unset "${!DOCKERSAND_@}" GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL="$fixture/gitconfig" GIT_CONFIG_NOSYSTEM=1
export XDG_STATE_HOME="$fixture/state" FAKE_DOCKER_ARGS_FILE="$fixture/args"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Makes $1 a git repository with one empty commit
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.test \
    commit -q --allow-empty -m initial
}

# A docker that captures the docker run argv, so no daemon is needed
install_fake_docker() {
  cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inspect && "${FAKE_EGRESS_PROXY:-}" == 1 ]]; then
  case "$3" in
    '{{.State.Running}}') echo true ;;
    *) echo 172.30.0.2 ;;
  esac
  exit 0
fi
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" >"$FAKE_DOCKER_ARGS_FILE"
  printf '%s' "${GH_TOKEN-unset}" >"$FAKE_DOCKER_ARGS_FILE.gh-token"
  # Stay up, as a sandbox would, until the test removes the hold file
  while [[ -n "${FAKE_DOCKER_HOLD:-}" && -e "$FAKE_DOCKER_HOLD" ]]; do sleep 0.2; done
  exit 0
fi
exit 1
EOF
  chmod +x "$fixture/bin/docker"
}

# Splits "[NAME=value...] [args...]" into env_args and cli_args. Launches are
# in mount mode unless the assignments set DOCKERSAND_GIT_STRATEGY.
split_env() {
  env_args=(DOCKERSAND_GIT_STRATEGY=mount)
  while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    env_args+=("$1")
    shift
  done
  cli_args=("$@")
}

# Launches from $repo with "[NAME=value...] [run arguments]", by default
# `test env`, and sets args to the captured docker run argv
run_sandbox() {
  split_env "$@"
  (( ${#cli_args[@]} )) || cli_args=(test env)
  (cd "$repo" && env "${env_args[@]}" "$launcher" run "${cli_args[@]}") \
    2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail "launcher failed: $*"; }
  mapfile -d '' -t args <"$FAKE_DOCKER_ARGS_FILE"
}

# Fails unless the launcher, given "[NAME=value...] [its arguments]", refuses
# without calling docker run. Its diagnostics are left in $fixture/stderr.
expect_rejected() {
  split_env "$@"
  rm -f "$FAKE_DOCKER_ARGS_FILE"
  if (cd "$repo" && env "${env_args[@]}" "$launcher" "${cli_args[@]}") >/dev/null 2>"$fixture/stderr"; then
    fail "accepted: $*"
  fi
  [[ ! -e "$FAKE_DOCKER_ARGS_FILE" ]] || fail "docker run called for: $*"
}

assert_arg() {
  local arg
  for arg in "${args[@]}"; do
    [[ "$arg" != "$1" ]] || return 0
  done
  fail "missing argument: $1"
}

assert_no_arg() {
  local arg
  for arg in "${args[@]}"; do
    [[ "$arg" != "$1" ]] || fail "unexpected argument: $1"
  done
}

# Fails if any argument matches the glob $1
assert_no_arg_matching() {
  local arg
  for arg in "${args[@]}"; do
    # shellcheck disable=SC2053  # Unquoted on purpose: $1 is a pattern
    [[ "$arg" != $1 ]] || fail "unexpected argument matching $1: $arg"
  done
}
