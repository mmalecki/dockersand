#!/usr/bin/env bash
set -euo pipefail

launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d)"
cleanup() {
  rm -rf "$fixture"
  [[ -z "${sudo_hook_installed:-}" ]] || if [[ -n "${preexisting_hook_dir:-}" ]]; then
    sudo -n rm -f /usr/local/libexec/dockersand/dockersand-args-test 2>/dev/null
  else
    sudo -n rm -rf /usr/local/libexec/dockersand 2>/dev/null
  fi
}
trap cleanup EXIT
mkdir -p "$fixture/bin" "$fixture/repo"
repo="$fixture/repo"
export GIT_CONFIG_GLOBAL="$fixture/gitconfig" GIT_CONFIG_NOSYSTEM=1
export XDG_STATE_HOME="$fixture/state" DOCKERSAND_ARGS_FILE="$fixture/args"
export FAKE_GCLOUD_TOKEN_FILE="$fixture/gcloud-token"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE EMAIL GIT_CONFIG_COUNT
unset DOCKERSAND_DIND DOCKERSAND_EGRESS DOCKERSAND_SESSION_NAME DOCKERSAND_SSH
unset DOCKERSAND_GCLOUD DOCKERSAND_GH GH_TOKEN XDG_RUNTIME_DIR DOCKERSAND_HOOK_DIR
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

# Capture the actual docker run argv; no daemon is needed for these tests.
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == run ]]; then
  printf '%s\0' "$@" >"$DOCKERSAND_ARGS_FILE"
  printf '%s' "${GH_TOKEN-unset}" >"$DOCKERSAND_ARGS_FILE.gh-token"
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
cat >"$fixture/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ -z "${FAKE_GH_FAIL:-}" && "$*" == "auth token" ]] || exit 1
echo gho_fake
EOF
chmod +x "$fixture/bin/docker" "$fixture/bin/gcloud" "$fixture/bin/gh"
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
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount env "$@" "$launcher" run test env) \
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
assert_no_arg --label
echo 'PASS: repository-only identity without global config'
git -C "$repo" config --remove-section user

git config --global user.name 'Global Name'
git config --global user.email global@example.test
run_sandbox
assert_identity 'Global Name' global@example.test
assert_arg --runtime=runsc
assert_arg --init
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
assert_arg io.dockersand.session=identity
checkout_name="$(basename "$repo")-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
assert_arg "io.dockersand.directory=$XDG_STATE_HOME/dockersand/repos/$checkout_name/identity"
echo 'PASS: clone strategy uses the host checkout identity'

for image in sessions run; do
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run "$image" sessions list) 2>"$fixture/stderr" ||
    { cat "$fixture/stderr" >&2; fail "launching image $image failed"; }
  mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
  [[ "${args[-3]}" == "$image" && "${args[-2]}" == sessions && "${args[-1]}" == list ]] ||
    fail "subcommand names were not passed through for image $image"
done
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run -- test -- --flag) 2>"$fixture/stderr" ||
  { cat "$fixture/stderr" >&2; fail 'run with -- failed'; }
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
[[ "${args[-3]}" == test && "${args[-2]}" == -- && "${args[-1]}" == --flag ]] ||
  fail 'run -- did not pass the app and its arguments through'
echo 'PASS: run passes subcommand names through as images and arguments, with an optional --'

for arguments in '' test '--sessions list' '-- test' 'run' 'run --'; do
  read -ra argv <<<"$arguments"
  rm -f "$DOCKERSAND_ARGS_FILE"
  if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" "${argv[@]}") >/dev/null 2>"$fixture/stderr"; then
    fail "accepted invalid arguments: $arguments"
  fi
  grep -Fq 'usage: dockersand run <app>' "$fixture/stderr" || fail "missing usage for: $arguments"
  [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail "docker run called for: $arguments"
done
for help in -h --help; do
  "$launcher" "$help" >"$fixture/stdout" || fail "$help failed"
  grep -Fq 'usage: dockersand run <app>' "$fixture/stdout" || fail "$help did not print usage"
done
echo 'PASS: bare apps and unknown subcommands print usage without launching'

# A repo-planted hook for a registry-path image must not run on the host
mkdir -p "$repo/dockersand-args-ghcr.io/acme"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$fixture/hook-marker" >"$repo/dockersand-args-ghcr.io/acme/tool"
chmod +x "$repo/dockersand-args-ghcr.io/acme/tool"
rm -f "$DOCKERSAND_ARGS_FILE"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run ghcr.io/acme/tool) 2>"$fixture/stderr" ||
  { cat "$fixture/stderr" >&2; fail 'registry-path launch failed'; }
[[ ! -e "$fixture/hook-marker" ]] || fail 'repo-controlled hook ran on the host'
[[ -s "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run not called for registry-path image'
rm -rf "$repo/dockersand-args-ghcr.io"
echo 'PASS: registry-path images do not run repo-controlled hooks'

# Hooks are resolved from the hook directory, never from PATH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" -e PATH_HOOK_RAN=1\n' >"$fixture/bin/dockersand-args-test"
chmod +x "$fixture/bin/dockersand-args-test"
run_sandbox
rm -f "$fixture/bin/dockersand-args-test"
assert_no_arg PATH_HOOK_RAN=1
echo 'PASS: PATH hooks are not used'

# A user-writable hook directory is never run from, explicit or not
mkdir -p "$fixture/hooks"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" -e HOOK_RAN=1\n' >"$fixture/hooks/dockersand-args-test"
chmod +x "$fixture/hooks/dockersand-args-test"
run_sandbox DOCKERSAND_HOOK_DIR="$fixture/hooks"
rm -rf "$fixture/hooks"
assert_no_arg HOOK_RAN=1
grep -Fq 'skipping hook' "$fixture/stderr" || fail 'user-writable hook directory was not skipped loudly'
echo 'PASS: user-writable hook directories are skipped, explicit or not'

# The default hook directory must be outside the invoking user's write-reach
if sudo -n true 2>/dev/null; then
  preexisting_hook_dir=0
  [[ ! -e /usr/local/libexec/dockersand ]] || preexisting_hook_dir=1
  sudo install -d -m 755 /usr/local/libexec/dockersand
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" -e ROOT_HOOK_RAN=1\n' >"$fixture/dockersand-args-test"
  sudo install -m 755 "$fixture/dockersand-args-test" /usr/local/libexec/dockersand/dockersand-args-test
  sudo_hook_installed=1

  run_sandbox
  assert_arg ROOT_HOOK_RAN=1
  grep -Fq 'user-writable' "$fixture/stderr" && fail 'unexpected notice for a root-owned hook'
  echo 'PASS: root-owned default hook directory is trusted'

  # A user-writable hook in the default directory is never run
  sudo chmod 777 /usr/local/libexec/dockersand/dockersand-args-test
  run_sandbox
  sudo chmod 755 /usr/local/libexec/dockersand/dockersand-args-test
  assert_no_arg ROOT_HOOK_RAN=1
  grep -Fq 'skipping hook' "$fixture/stderr" || fail 'untrusted default hook was not skipped loudly'
  echo 'PASS: user-writable hooks in the default directory are skipped'

  # Trusted explicitly too, without a warning
  run_sandbox DOCKERSAND_HOOK_DIR=/usr/local/libexec/dockersand
  assert_arg ROOT_HOOK_RAN=1
  grep -Fq 'user-writable' "$fixture/stderr" && fail 'unexpected warning for a trusted DOCKERSAND_HOOK_DIR'
  echo 'PASS: DOCKERSAND_HOOK_DIR pointing at a trusted directory is quiet'

  if ((preexisting_hook_dir)); then
    sudo rm -f /usr/local/libexec/dockersand/dockersand-args-test
  else
    sudo rm -rf /usr/local/libexec/dockersand
  fi
  sudo_hook_installed=
else
  echo 'SKIP: no passwordless sudo; the default hook directory is not tested'
fi

for bad in "--privileged alpine" "-- --privileged alpine"; do
  rm -f "$DOCKERSAND_ARGS_FILE"
  # shellcheck disable=SC2086
  if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run $bad) 2>/dev/null; then
    fail "launched with option-like app: $bad"
  fi
  [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail "docker run called for: $bad"
done
echo 'PASS: option-like app names are rejected'

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
assert_arg --init
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
  "$launcher" run test env) 2>"$fixture/stderr" &
sandbox=$!
wait_for test -s "$DOCKERSAND_ARGS_FILE" || { cat "$fixture/stderr" >&2; fail 'launcher did not start'; }
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
assert_arg CLOUDSDK_AUTH_ACCESS_TOKEN_FILE=/run/secrets/gcloud/token
assert_arg CLOUDSDK_CORE_PROJECT=fake-project
# The token directory, from the gcloud --mount value in args
gcloud_token_dir() {
  local arg
  token_dir=""
  for arg in "${args[@]}"; do
    [[ "$arg" != *'","dst=/run/secrets/gcloud",readonly' ]] || token_dir="${arg#type=bind,\"src=}"
  done
  token_dir="${token_dir%\",\"dst=/run/secrets/gcloud\",readonly}"
}
gcloud_token_dir
[[ -n "$token_dir" && "$(cat "$token_dir/token")" == fake-token ]] || fail 'token not mounted'
[[ "$(stat -c %a "$(dirname "$token_dir")")" == 700 ]] || fail 'token directory not private'
assert_arg "type=bind,\"src=$token_dir\",\"dst=/run/secrets/gcloud\",readonly"
echo 'PASS: opt-in gcloud token forwarding'

echo refreshed >"$FAKE_GCLOUD_TOKEN_FILE"
touch -d '3 minutes ago' "$token_dir/token"
wait_for grep -qx refreshed "$token_dir/token" || fail 'token not refreshed'
echo 'PASS: gcloud token refreshes while the sandbox runs'

rm "$fixture/hold"
wait "$sandbox" || fail 'launcher failed'
wait_for test ! -e "$token_dir" || fail 'token left behind after the sandbox quit'
echo 'PASS: gcloud token deleted when the sandbox quits'

# The launcher's parent execs sleep, which never reaps it, so the exited
# docker run stays a zombie
rm -f "$DOCKERSAND_ARGS_FILE"
touch "$fixture/hold"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=1 FAKE_DOCKER_HOLD="$fixture/hold" \
  exec bash -c '"$0" run test env & exec sleep 60' "$launcher") 2>"$fixture/stderr" &
parent=$!
wait_for test -s "$DOCKERSAND_ARGS_FILE" || { cat "$fixture/stderr" >&2; fail 'launcher did not start'; }
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
gcloud_token_dir
[[ -n "$token_dir" ]] || fail 'token not mounted'
rm "$fixture/hold"
wait_for test ! -e "$token_dir" || fail 'token left behind while the sandbox is a zombie'
kill "$parent"
wait "$parent" 2>/dev/null || true
echo 'PASS: gcloud token deleted when the sandbox quits unreaped'

if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=1 FAKE_GCLOUD_FAIL=1 \
  "$launcher" run test env) 2>/dev/null; then
  fail 'launched without a gcloud token'
fi
for dir in "$XDG_STATE_HOME"/dockersand/gcloud.*; do
  [[ ! -e "$dir" ]] || fail "token directory left behind: $dir"
done
echo 'PASS: gcloud token failure prevents launch'

run_sandbox
assert_no_arg GH_TOKEN
[[ "$(<"$DOCKERSAND_ARGS_FILE.gh-token")" == unset ]] || fail 'gh token passed without DOCKERSAND_GH'

run_sandbox DOCKERSAND_GH=1
assert_arg GH_TOKEN
for arg in "${args[@]}"; do
  [[ "$arg" != *gho_fake* ]] || fail 'gh token in docker run arguments'
done
[[ "$(<"$DOCKERSAND_ARGS_FILE.gh-token")" == gho_fake ]] || fail 'gh token not passed to docker'
echo 'PASS: opt-in gh token forwarding'

rm -f "$DOCKERSAND_ARGS_FILE"
if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GH=1 FAKE_GH_FAIL=1 \
  "$launcher" run test env) 2>/dev/null; then
  fail 'launched without a gh token'
fi
[[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called without a gh token'
echo 'PASS: gh token failure prevents launch'

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

# Docker splits -v on ':' and parses --mount as CSV, so odd names need quoting
assert_no_v() {
  local arg
  for arg in "${args[@]}"; do
    [[ "$arg" != -v && "$arg" != -v* ]] || fail "-v form used: $arg"
  done
}

weird='we:ird,na"me'
weird_q='we:ird,na""me'
repo="$fixture/$weird"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.test \
  commit -q --allow-empty -m initial
real="$(realpath "$repo")"
real_q="${real//\"/\"\"}"

run_sandbox
assert_no_v
assert_arg --mount
assert_arg "type=bind,\"src=$real_q\",\"dst=/home/work/repos/$weird_q\""
echo 'PASS: mount strategy quotes a project directory with : , and "'

run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION_NAME=weird
assert_no_v
checkout_name="$weird-$(printf %s "$real" | sha256sum | cut -c1-8)"
assert_arg "type=bind,\"src=${XDG_STATE_HOME//\"/\"\"}/dockersand/repos/${checkout_name//\"/\"\"}/weird\",\"dst=/home/work/repos\""
echo 'PASS: clone strategy quotes a state directory with : , and "'

mkdir -p "$fixture/home/.ssh"
touch "$fixture/home/.ssh/known_hosts"
run_sandbox DOCKERSAND_SSH=1 "HOME=$fixture/home" "SSH_AUTH_SOCK=$fixture/ssh:agent.sock"
assert_no_v
assert_arg "type=bind,\"src=$fixture/ssh:agent.sock\",\"dst=/tmp/ssh-agent.sock\""
assert_arg "type=bind,\"src=$fixture/home/.ssh/known_hosts\",\"dst=/home/work/.ssh/known_hosts\",readonly"
echo 'PASS: SSH mounts are quoted and known_hosts is read-only'
