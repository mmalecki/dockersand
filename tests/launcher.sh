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
unset DOCKERSAND_DIND DOCKERSAND_EGRESS DOCKERSAND_SESSION DOCKERSAND_SSH
unset DOCKERSAND_GCLOUD DOCKERSAND_GH GH_TOKEN XDG_RUNTIME_DIR
unset DOCKERSAND_DBUS DOCKERSAND_ENTRYPOINT DOCKERSAND_HOST_GATEWAY DOCKERSAND_GIT_STRATEGY
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

# Capture the actual docker run argv; no daemon is needed for these tests.
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

run_cli() {
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run "$@") \
    2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail 'launcher failed'; }
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

run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=identity
assert_identity 'Local Name' local@example.test
assert_arg io.dockersand.session=identity
checkout_name="$(basename "$repo")-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
assert_arg "io.dockersand.directory=$XDG_STATE_HOME/dockersand/repos/$checkout_name/identity"
echo 'PASS: clone strategy uses the host checkout identity'

cp "$DOCKERSAND_ARGS_FILE" "$fixture/session-args"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_SESSION=ignored \
  "$launcher" run --session identity --git-strategy clone -- test env) \
  2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail '--session launch failed'; }
cmp -s "$fixture/session-args" "$DOCKERSAND_ARGS_FILE" || fail '--session did not resume the environment-selected session'
echo 'PASS: --session overrides the environment and resumes the same clone'

for options in '--session' '--session --ssh test' '--session ../escape test' '--session . test' '--session .. test'; do
  read -ra argv <<<"$options"
  rm -f "$DOCKERSAND_ARGS_FILE"
  if (cd "$repo" && "$launcher" run "${argv[@]}") 2>"$fixture/stderr"; then
    fail "accepted invalid session arguments: $options"
  fi
  [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail "docker run called for: $options"
done
if (cd "$repo" && "$launcher" run --session '' test) 2>"$fixture/stderr"; then
  fail 'accepted empty session name'
fi
if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run --session identity test) 2>"$fixture/stderr"; then
  fail 'accepted --session with mount strategy'
fi
rg -Fq 'DOCKERSAND_SESSION needs DOCKERSAND_GIT_STRATEGY=clone' "$fixture/stderr" || fail 'missing session strategy diagnostic'
[[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called for an invalid session'
echo 'PASS: invalid session names, missing values and mount strategy are rejected'

for option in --git-strategy --entrypoint --host-gateway; do
  for suffix in '' '--ssh test'; do
    read -ra argv <<<"$suffix"
    if (cd "$repo" && "$launcher" run "$option" "${argv[@]}") 2>"$fixture/stderr"; then
      fail "accepted missing value for $option"
    fi
    rg -Fq -- "$option requires a value" "$fixture/stderr" || fail "missing diagnostic for $option"
    [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail "docker run called without a value for $option"
  done
done
if (cd "$repo" && "$launcher" run --git-strategy invalid test) 2>"$fixture/stderr"; then
  fail 'accepted invalid git strategy'
fi
[[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called for an invalid git strategy'
echo 'PASS: valued switches reject missing arguments and invalid git strategies'

run_sandbox DOCKERSAND_ENTRYPOINT='/path with spaces/bash' DOCKERSAND_HOST_GATEWAY=host.internal
assert_arg --entrypoint
assert_arg '/path with spaces/bash'
assert_arg host.internal:host-gateway
cp "$DOCKERSAND_ARGS_FILE" "$fixture/value-args"
DOCKERSAND_ENTRYPOINT=ignored DOCKERSAND_HOST_GATEWAY=ignored \
  run_cli --git-strategy mount --entrypoint '/path with spaces/bash' --host-gateway host.internal test env
cmp -s "$fixture/value-args" "$DOCKERSAND_ARGS_FILE" || fail 'valued switches differ from environment settings'
DOCKERSAND_ENTRYPOINT=ignored DOCKERSAND_HOST_GATEWAY=ignored \
  run_cli --entrypoint '' --host-gateway '' test env
assert_no_arg --entrypoint
assert_no_arg --add-host
echo 'PASS: entrypoint and host gateway switches override environment values, including empty values'

run_sandbox DOCKERSAND_EGRESS=1 FAKE_EGRESS_PROXY=1
assert_arg dockersand-internal
assert_arg HTTP_PROXY=http://172.30.0.2:3128
assert_no_arg --add-host
cp "$DOCKERSAND_ARGS_FILE" "$fixture/egress-args"
DOCKERSAND_EGRESS=0 FAKE_EGRESS_PROXY=1 run_cli --egress test env
cmp -s "$fixture/egress-args" "$DOCKERSAND_ARGS_FILE" || fail '--egress differs from DOCKERSAND_EGRESS=1'
rm -f "$DOCKERSAND_ARGS_FILE"
if (cd "$repo" && "$launcher" run --egress test) 2>"$fixture/stderr"; then
  fail 'accepted --egress without a running proxy'
fi
[[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail 'docker run called without an egress proxy'
echo 'PASS: --egress matches the environment opt-in and requires a running proxy'

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

for arguments in '' test '--sessions list' '-- test' 'run' 'run --' 'run --dind' 'run --dind --'; do
  read -ra argv <<<"$arguments"
  rm -f "$DOCKERSAND_ARGS_FILE"
  if (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" "${argv[@]}") >/dev/null 2>"$fixture/stderr"; then
    fail "accepted invalid arguments: $arguments"
  fi
  rg -Fq 'usage: dockersand run [options] [--] <app>' "$fixture/stderr" || fail "missing usage for: $arguments"
  [[ ! -e "$DOCKERSAND_ARGS_FILE" ]] || fail "docker run called for: $arguments"
done
for help in -h --help; do
  "$launcher" "$help" >"$fixture/stdout" || fail "$help failed"
  rg -Fq 'usage: dockersand run [options] [--] <app>' "$fixture/stdout" || fail "$help did not print usage"
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

# Hooks for slash-free app names are still found on PATH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" -e HOOK_RAN=1\n' >"$fixture/bin/dockersand-args-test"
chmod +x "$fixture/bin/dockersand-args-test"
run_sandbox
rm -f "$fixture/bin/dockersand-args-test"
assert_arg HOOK_RAN=1
echo 'PASS: PATH hooks run for bare app names'

for bad in "--privileged alpine" "-- --privileged alpine" "--dind --privileged alpine" "-- --dind alpine"; do
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
run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=worktree
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

cp "$DOCKERSAND_ARGS_FILE" "$fixture/dind-args"
for setting in '' 0 1; do
  for options in '--dind' '--dind --' '--dind --dind'; do
    read -ra argv <<<"$options"
    (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_DIND="$setting" \
      "$launcher" run "${argv[@]}" test env) 2>"$fixture/stderr" ||
      { cat "$fixture/stderr" >&2; fail '--dind launch failed'; }
    cmp -s "$fixture/dind-args" "$DOCKERSAND_ARGS_FILE" || fail '--dind differs from DOCKERSAND_DIND=1'
  done
done
echo 'PASS: --dind matches the environment opt-in and overrides DOCKERSAND_DIND=0'

app_args=(--dind --dbus --gcloud --gh --ssh --egress --session 'two words' --git-strategy mount --entrypoint /bin/bash --host-gateway '')
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount "$launcher" run test "${app_args[@]}") \
  2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail 'app argument launch failed'; }
mapfile -d '' -t args <"$DOCKERSAND_ARGS_FILE"
assert_arg --runtime=runsc
assert_no_arg DOCKERSAND_DIND=1
[[ "${args[$(( ${#args[@]} - ${#app_args[@]} - 1 ))]}" == test ]] || fail 'app was not preserved'
for i in "${!app_args[@]}"; do
  [[ "${args[$(( ${#args[@]} - ${#app_args[@]} + i ))]}" == "${app_args[$i]}" ]] ||
    fail 'app arguments were not preserved'
done
echo 'PASS: switches after the app are passed through without enabling integrations'

run_sandbox
for arg in "${args[@]}"; do
  [[ "$arg" != CLOUDSDK_* && "$arg" != */run/secrets/gcloud* ]] || fail 'unexpected gcloud argument'
done

rm -f "$DOCKERSAND_ARGS_FILE"
touch "$fixture/hold"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=0 FAKE_DOCKER_HOLD="$fixture/hold" \
  "$launcher" run --gcloud test env) 2>"$fixture/stderr" &
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

cp "$DOCKERSAND_ARGS_FILE" "$fixture/gh-args"
DOCKERSAND_GH=0 run_cli --gh test env
cmp -s "$fixture/gh-args" "$DOCKERSAND_ARGS_FILE" || fail '--gh differs from DOCKERSAND_GH=1'
[[ "$(<"$DOCKERSAND_ARGS_FILE.gh-token")" == gho_fake ]] || fail '--gh did not pass the token to Docker'
echo 'PASS: --gh matches the environment opt-in and overrides DOCKERSAND_GH=0'

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

run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=weird
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

cp "$DOCKERSAND_ARGS_FILE" "$fixture/ssh-args"
(cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_SSH=0 \
  HOME="$fixture/home" SSH_AUTH_SOCK="$fixture/ssh:agent.sock" "$launcher" run --ssh test env) \
  2>"$fixture/stderr" || { cat "$fixture/stderr" >&2; fail '--ssh launch failed'; }
cmp -s "$fixture/ssh-args" "$DOCKERSAND_ARGS_FILE" || fail '--ssh differs from DOCKERSAND_SSH=1'
echo 'PASS: --ssh matches the environment opt-in and overrides DOCKERSAND_SSH=0'
