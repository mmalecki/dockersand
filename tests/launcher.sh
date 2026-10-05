#!/usr/bin/env bash
set -euo pipefail

launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repo"
repo="$fixture/repo"
export GIT_CONFIG_GLOBAL="$fixture/gitconfig" GIT_CONFIG_NOSYSTEM=1
export XDG_STATE_HOME="$fixture/state" DOCKERSAND_ARGS_FILE="$fixture/args"
export FAKE_GCLOUD_TOKEN_FILE="$fixture/gcloud-token"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE EMAIL GIT_CONFIG_COUNT
unset DOCKERSAND_DIND DOCKERSAND_EGRESS DOCKERSAND_SESSION_NAME DOCKERSAND_SSH
unset DOCKERSAND_GCLOUD XDG_RUNTIME_DIR
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

# Capture the actual docker run argv; no daemon is needed for these tests.
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" >"$DOCKERSAND_ARGS_FILE"
  # Stay up, as a sandbox would, until the test removes the hold file
  while [[ -n "${FAKE_DOCKER_HOLD:-}" && -e "$FAKE_DOCKER_HOLD" ]]; do sleep 0.2; done
  exit 0
fi
exit 1
EOF
cat >"$fixture/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
[[ -z "${FAKE_GCLOUD_FAIL:-}" ]] || exit 1
case "$*" in
  "auth print-access-token") cat "$FAKE_GCLOUD_TOKEN_FILE" 2>/dev/null || echo fake-token ;;
  "config get project") echo fake-project ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/docker" "$fixture/bin/gcloud"
export PATH="$fixture/bin:$PATH"
git -C "$repo" init -q
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.test \
  commit -q --allow-empty -m initial

fail() { echo "FAIL: $*" >&2; exit 1; }

wait_for() {
  local i
  for ((i = 0; i < 100; i++)); do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}

run_sandbox() {
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount env "$@" "$launcher" test env) \
    2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail "launcher failed"; }
  mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
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

assert_identity() {
  assert_arg "GIT_AUTHOR_NAME=$1"
  assert_arg "GIT_AUTHOR_EMAIL=$2"
  assert_arg "GIT_COMMITTER_NAME=${3:-$1}"
  assert_arg "GIT_COMMITTER_EMAIL=${4:-$2}"
}

git -C "$repo" config user.name 'Repository Only'
git -C "$repo" config user.email repository@example.test
run_sandbox
assert_identity 'Repository Only' repository@example.test
echo 'PASS: repository-only identity without global config'
git -C "$repo" config --remove-section user

git config --global user.name 'Global Name'
git config --global user.email global@example.test
run_sandbox
assert_identity 'Global Name' global@example.test
assert_arg --runtime=runsc
assert_arg no-new-privileges
assert_no_arg SYS_ADMIN
assert_no_arg DOCKERSAND_DIND=1
echo 'PASS: global identity and default isolation'

git -C "$repo" config user.name 'Local Name'
git -C "$repo" config user.email local@example.test
run_sandbox
assert_identity 'Local Name' local@example.test
echo 'PASS: repository config overrides global identity'

run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION_NAME=identity
assert_identity 'Local Name' local@example.test
echo 'PASS: clone strategy uses the host checkout identity'

run_sandbox 'GIT_AUTHOR_NAME=Env Author' GIT_AUTHOR_EMAIL=author@example.test \
  'GIT_COMMITTER_NAME=Env Committer' GIT_COMMITTER_EMAIL=committer@example.test \
  GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z'
assert_identity 'Env Author' author@example.test 'Env Committer' committer@example.test
for arg in "${args[@]}"; do
  [[ "$arg" != GIT_AUTHOR_DATE=* && "$arg" != GIT_COMMITTER_DATE=* ]] || fail 'timestamp forwarded'
done
echo 'PASS: separate environment overrides without timestamps'

run_sandbox 'GIT_AUTHOR_NAME=Author Only'
assert_identity 'Author Only' local@example.test 'Local Name' local@example.test
echo 'PASS: partial environment override falls back to config'

git -C "$repo" config author.name 'Configured Author'
git -C "$repo" config author.email configured-author@example.test
git -C "$repo" config committer.name 'Configured Committer'
git -C "$repo" config committer.email configured-committer@example.test
run_sandbox
assert_identity 'Configured Author' configured-author@example.test \
  'Configured Committer' configured-committer@example.test
echo 'PASS: author and committer config'
git -C "$repo" config --remove-section author
git -C "$repo" config --remove-section committer
git -C "$repo" config --remove-section user

git config --file "$fixture/included" user.name 'Conditional Name'
git config --file "$fixture/included" user.email conditional@example.test
git config --global "includeIf.gitdir:$repo/.git.path" "$fixture/included"
run_sandbox
assert_identity 'Conditional Name' conditional@example.test
echo 'PASS: conditional include'

git -C "$repo" worktree add -q "$fixture/worktree" -b linked
git config --global "includeIf.gitdir:$repo/.git/worktrees/.path" "$fixture/included"
repo="$fixture/worktree"
run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION_NAME=worktree
assert_identity 'Conditional Name' conditional@example.test
echo 'PASS: conditional identity from a linked worktree'

run_sandbox DOCKERSAND_DIND=1
assert_arg --runtime=runc
assert_arg SYS_ADMIN
assert_arg seccomp=unconfined
assert_arg apparmor=unconfined
assert_arg systempaths=unconfined
assert_arg /dev/net/tun
assert_arg DOCKERSAND_DIND=1
assert_no_arg --runtime=runsc
assert_no_arg no-new-privileges
assert_no_arg --privileged
echo 'PASS: opt-in rootless Docker permissions'

run_sandbox
for arg in "${args[@]}"; do
  [[ "$arg" != CLOUDSDK_* && "$arg" != */run/secrets/gcloud* ]] || fail 'unexpected gcloud argument'
done

rm -f "$DOCKERSAND_ARGS_FILE"
touch "$fixture/hold"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=1 FAKE_DOCKER_HOLD="$fixture/hold" \
  "$launcher" test env) 2>"$fixture/stderr" &
sandbox=$!
wait_for test -s "$DOCKERSAND_ARGS_FILE" || { cat "$fixture/stderr" >&2; fail 'launcher did not start'; }
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
assert_arg CLOUDSDK_AUTH_ACCESS_TOKEN_FILE=/run/secrets/gcloud/token
assert_arg CLOUDSDK_CORE_PROJECT=fake-project
token_dir=""
for arg in "${args[@]}"; do
  [[ "$arg" != *:/run/secrets/gcloud:ro ]] || token_dir="${arg%:/run/secrets/gcloud:ro}"
done
[[ -n "$token_dir" && "$(cat "$token_dir/token")" == fake-token ]] || fail 'token not mounted'
[[ "$(stat -c %a "$(dirname "$token_dir")")" == 700 ]] || fail 'token directory not private'
echo 'PASS: opt-in gcloud token forwarding'

echo refreshed >"$FAKE_GCLOUD_TOKEN_FILE"
touch -d '1 hour ago' "$token_dir/token"
wait_for grep -qx refreshed "$token_dir/token" || fail 'token not refreshed'
echo 'PASS: gcloud token refreshes while the sandbox runs'

rm "$fixture/hold"
wait "$sandbox" || fail 'launcher failed'
wait_for test ! -e "$token_dir" || fail 'token left behind after the sandbox quit'
echo 'PASS: gcloud token deleted when the sandbox quits'

if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=1 FAKE_GCLOUD_FAIL=1 \
  "$launcher" test env) 2>/dev/null; then
  fail 'launched without a gcloud token'
fi
for dir in "$XDG_STATE_HOME"/dockersand/gcloud.*; do
  [[ ! -e "$dir" ]] || fail "token directory left behind: $dir"
done
echo 'PASS: gcloud token failure prevents launch'

: >"$GIT_CONFIG_GLOBAL"
git config --global user.useConfigOnly true
run_sandbox
for arg in "${args[@]}"; do
  [[ "$arg" != GIT_AUTHOR_*=* && "$arg" != GIT_COMMITTER_*=* ]] || fail 'unexpected identity'
done
echo 'PASS: missing identity does not prevent launch'

repo="$fixture/plain"
mkdir -p "$repo"
git config --global user.name 'Directory User'
git config --global user.email directory@example.test
run_sandbox
assert_identity 'Directory User' directory@example.test
echo 'PASS: identity outside a git repository'
