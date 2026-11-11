#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export FAKE_GCLOUD_TOKEN_FILE="$fixture/gcloud-token"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE EMAIL
unset GH_TOKEN XDG_RUNTIME_DIR

install_fake_docker
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
chmod +x "$fixture/bin/gcloud" "$fixture/bin/gh"
make_repo "$repo"

wait_for() {
  local i
  for ((i = 0; i < 100; i++)); do
    "$@" && return 0
    sleep 0.2
  done
  return 1
}

assert_identity() {
  assert_arg "GIT_AUTHOR_NAME=$1"
  assert_arg "GIT_AUTHOR_EMAIL=$2"
  assert_arg "GIT_COMMITTER_NAME=${3:-$1}"
  assert_arg "GIT_COMMITTER_EMAIL=${4:-$2}"
}

# Each -p value, in order
published() {
  local i
  ports=()
  for i in "${!args[@]}"; do
    [[ "${args[$i]}" != -p ]] || ports+=("${args[$((i + 1))]}")
  done
}

# The token directory, from the gcloud --mount value in args
gcloud_token_dir() {
  local arg
  token_dir=""
  for arg in "${args[@]}"; do
    [[ "$arg" != *'","dst=/run/secrets/gcloud",readonly' ]] || token_dir="${arg#type=bind,\"src=}"
  done
  token_dir="${token_dir%\",\"dst=/run/secrets/gcloud\",readonly}"
}

# The tests below run in the order they're called at the end of this file,
# and some build on Git config, sessions or launches left by earlier ones.

test_repository_identity_without_global_config() {
  git -C "$repo" config user.name 'Repository Only'
  git -C "$repo" config user.email repository@example.test
  run_sandbox
  assert_identity 'Repository Only' repository@example.test
  assert_no_arg --label
  echo 'PASS: repository-only identity without global config'
  git -C "$repo" config --remove-section user
}

test_global_identity_and_default_isolation() {
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
}

test_repository_identity_overrides_global() {
  git -C "$repo" config user.name 'Local Name'
  git -C "$repo" config user.email local@example.test
  run_sandbox
  assert_identity 'Local Name' local@example.test
  echo 'PASS: repository config overrides global identity'
}

# Sets checkout_name and session_dir for the session tests that follow
test_clone_uses_host_checkout_identity() {
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=identity
  assert_identity 'Local Name' local@example.test
  assert_arg io.dockersand.session=identity
  checkout_name="$(basename "$repo")-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
  session_dir="$XDG_STATE_HOME/dockersand/sessions/$checkout_name/identity"
  assert_arg "io.dockersand.directory=$session_dir"
  echo 'PASS: clone strategy uses the host checkout identity'
}

test_clone_session_keeps_repos_and_tmp_together() {
  assert_arg "type=bind,\"src=$session_dir/repos\",\"dst=/home/work/repos\""
  assert_arg "type=bind,\"src=$session_dir/tmp\",\"dst=/tmp\""
  [[ -d "$session_dir/repos/$(basename "$repo")/.git" ]] || fail 'clone is not under the session repos directory'
  [[ "$(stat -c %a "$session_dir")" == 700 ]] || fail 'session directory is not private'
  [[ "$(stat -c %a "$session_dir/tmp")" == 1777 ]] || fail 'session tmp is not 1777'
  echo 'PASS: clone sessions keep repos and /tmp under one private session directory'
}

test_ephemeral_tmp_skips_session_tmp() {
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/persistent-tmp-args"
  touch "$session_dir/tmp/scratch"
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=identity DOCKERSAND_EPHEMERAL_TMP=1
  assert_no_arg "type=bind,\"src=$session_dir/tmp\",\"dst=/tmp\""
  assert_arg "type=bind,\"src=$session_dir/repos\",\"dst=/home/work/repos\""
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/ephemeral-tmp-args"
  # Empty selects the default strategy
  run_sandbox DOCKERSAND_GIT_STRATEGY= DOCKERSAND_EPHEMERAL_TMP=0 --session identity --ephemeral-tmp test env
  cmp -s "$fixture/ephemeral-tmp-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--ephemeral-tmp differs from DOCKERSAND_EPHEMERAL_TMP=1'
  [[ -e "$session_dir/tmp/scratch" ]] || fail 'an ephemeral run removed the saved /tmp'
  run_sandbox
  assert_no_arg_matching '*"dst=/tmp"*'
  # Last, as the resume test below compares against this launch
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=identity DOCKERSAND_EPHEMERAL_TMP=0
  cmp -s "$fixture/persistent-tmp-args" "$FAKE_DOCKER_ARGS_FILE" || fail 'resuming changed the session /tmp mount'
  echo 'PASS: --ephemeral-tmp opts out of the session /tmp, which mount mode never has'
}

test_session_switch_resumes_clone() {
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/session-args"
  run_sandbox DOCKERSAND_SESSION=ignored --session identity --git-strategy clone -- test env
  cmp -s "$fixture/session-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--session did not resume the environment-selected session'
  echo 'PASS: --session overrides the environment and resumes the same clone'
}

test_invalid_sessions_rejected() {
  local options argv
  for options in '--session' '--session --ssh test' '--session ../escape test' '--session . test' '--session .. test'; do
    read -ra argv <<<"$options"
    expect_rejected DOCKERSAND_GIT_STRATEGY=clone run "${argv[@]}"
  done
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone run --session '' test
  expect_rejected run --session identity test
  grep -Fq 'DOCKERSAND_SESSION needs DOCKERSAND_GIT_STRATEGY=clone' "$fixture/stderr" || fail 'missing session strategy diagnostic'
  echo 'PASS: invalid session names, missing values and mount strategy are rejected'
}

test_valued_switches_need_values() {
  local option suffix argv
  for option in --git-strategy --entrypoint --host-gateway; do
    for suffix in '' '--ssh test'; do
      read -ra argv <<<"$suffix"
      expect_rejected run "$option" "${argv[@]}"
      grep -Fq -- "$option requires a value" "$fixture/stderr" || fail "missing diagnostic for $option"
    done
  done
  expect_rejected run --git-strategy invalid test
  echo 'PASS: valued switches reject missing arguments and invalid git strategies'
}

test_entrypoint_and_host_gateway_switches() {
  run_sandbox DOCKERSAND_ENTRYPOINT='/path with spaces/bash' DOCKERSAND_HOST_GATEWAY=host.internal
  assert_arg --entrypoint
  assert_arg '/path with spaces/bash'
  assert_arg host.internal:host-gateway
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/value-args"
  run_sandbox DOCKERSAND_ENTRYPOINT=ignored DOCKERSAND_HOST_GATEWAY=ignored \
    --git-strategy mount --entrypoint '/path with spaces/bash' --host-gateway host.internal test env
  cmp -s "$fixture/value-args" "$FAKE_DOCKER_ARGS_FILE" || fail 'valued switches differ from environment settings'
  run_sandbox DOCKERSAND_ENTRYPOINT=ignored DOCKERSAND_HOST_GATEWAY=ignored --entrypoint '' --host-gateway '' test env
  assert_no_arg --entrypoint
  assert_no_arg --add-host
  echo 'PASS: entrypoint and host gateway switches override environment values, including empty values'
}

test_published_ports_default_to_loopback() {
  local expected
  run_sandbox
  published
  (( ! ${#ports[@]} )) || fail 'ports published without DOCKERSAND_PUBLISH'
  run_sandbox DOCKERSAND_PUBLISH='80 8080:80 8000-8010:8000-8010/udp 0.0.0.0:9090:90 [::1]:9091:91/tcp 127.0.0.2::92'
  published
  expected=(127.0.0.1::80 127.0.0.1:8080:80 127.0.0.1:8000-8010:8000-8010/udp 0.0.0.0:9090:90 '[::1]:9091:91/tcp' 127.0.0.2::92)
  [[ "${ports[*]}" == "${expected[*]}" ]] || fail "unexpected published ports: ${ports[*]}"
  echo 'PASS: published ports default to loopback and keep explicit host addresses'
}

test_publish_switches_override_environment() {
  run_sandbox DOCKERSAND_PUBLISH=ignored -p 80 --publish 8080:80 test env
  published
  [[ "${ports[*]}" == '127.0.0.1::80 127.0.0.1:8080:80' ]] || fail "-p did not replace the environment: ${ports[*]}"
  echo 'PASS: -p and --publish repeat and override DOCKERSAND_PUBLISH'
}

test_invalid_ports_rejected() {
  local options argv
  for options in '-p' '--publish' '-p --ssh test' '-p -1 test' '-p 80:80:80:80 test' '-p host:80:80 test' '-p 80/icmp test' '-p :80 test'; do
    read -ra argv <<<"$options"
    expect_rejected run "${argv[@]}"
  done
  expect_rejected run -p '80 81' test
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=badport run -p bad test
  [[ ! -e "$XDG_STATE_HOME/dockersand/sessions/$checkout_name/badport" ]] ||
    fail 'invalid port left a session behind'
  expect_rejected FAKE_EGRESS_PROXY=1 run --egress -p 80 test
  grep -Fq "DOCKERSAND_PUBLISH doesn't work with DOCKERSAND_EGRESS=1" "$fixture/stderr" || fail 'missing egress diagnostic'
  echo 'PASS: invalid ports and publishing with egress filtering are rejected'
}

test_egress_switch_needs_running_proxy() {
  run_sandbox DOCKERSAND_EGRESS=1 FAKE_EGRESS_PROXY=1
  assert_arg dockersand-internal
  assert_arg HTTP_PROXY=http://172.30.0.2:3128
  assert_no_arg --add-host
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/egress-args"
  run_sandbox DOCKERSAND_EGRESS=0 FAKE_EGRESS_PROXY=1 --egress test env
  cmp -s "$fixture/egress-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--egress differs from DOCKERSAND_EGRESS=1'
  expect_rejected run --egress test
  echo 'PASS: --egress matches the environment opt-in and requires a running proxy'
}

test_run_passes_subcommand_names_through() {
  local image
  for image in sessions run; do
    run_sandbox "$image" sessions list
    [[ "${args[-3]}" == "$image" && "${args[-2]}" == sessions && "${args[-1]}" == list ]] ||
      fail "subcommand names were not passed through for image $image"
  done
  run_sandbox -- test -- --flag
  [[ "${args[-3]}" == test && "${args[-2]}" == -- && "${args[-1]}" == --flag ]] ||
    fail 'run -- did not pass the app and its arguments through'
  echo 'PASS: run passes subcommand names through as images and arguments, with an optional --'
}

test_bare_apps_and_unknown_subcommands_print_usage() {
  local arguments argv help
  for arguments in '' test '--sessions list' '-- test' 'run' 'run --' 'run --dind' 'run --dind --'; do
    read -ra argv <<<"$arguments"
    expect_rejected "${argv[@]}"
    grep -Fq 'usage: dockersand run [options] [--] <app>' "$fixture/stderr" || fail "missing usage for: $arguments"
  done
  for help in -h --help; do
    "$launcher" "$help" >"$fixture/stdout" || fail "$help failed"
    grep -Fq 'usage: dockersand run [options] [--] <app>' "$fixture/stdout" || fail "$help did not print usage"
  done
  echo 'PASS: bare apps and unknown subcommands print usage without launching'
}

# A repo-planted hook for a registry-path image must not run on the host
test_registry_path_images_skip_repo_hooks() {
  mkdir -p "$repo/dockersand-args-ghcr.io/acme"
  printf '#!/usr/bin/env bash\ntouch "%s"\n' "$fixture/hook-marker" >"$repo/dockersand-args-ghcr.io/acme/tool"
  chmod +x "$repo/dockersand-args-ghcr.io/acme/tool"
  rm -f "$FAKE_DOCKER_ARGS_FILE"
  run_sandbox ghcr.io/acme/tool
  [[ ! -e "$fixture/hook-marker" ]] || fail 'repo-controlled hook ran on the host'
  [[ -s "$FAKE_DOCKER_ARGS_FILE" ]] || fail 'docker run not called for registry-path image'
  rm -rf "$repo/dockersand-args-ghcr.io"
  echo 'PASS: registry-path images do not run repo-controlled hooks'
}

# Hooks for slash-free app names are still found on PATH
test_path_hooks_run_for_bare_apps() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" -e HOOK_RAN=1\n' >"$fixture/bin/dockersand-args-test"
  chmod +x "$fixture/bin/dockersand-args-test"
  run_sandbox
  rm -f "$fixture/bin/dockersand-args-test"
  assert_arg HOOK_RAN=1
  echo 'PASS: PATH hooks run for bare app names'
}

test_option_like_app_names_rejected() {
  local bad argv
  for bad in "--privileged alpine" "-- --privileged alpine" "--dind --privileged alpine" "-- --dind alpine"; do
    read -ra argv <<<"$bad"
    expect_rejected run "${argv[@]}"
  done
  echo 'PASS: option-like app names are rejected'
}

test_environment_identity_without_timestamps() {
  run_sandbox 'GIT_AUTHOR_NAME=Env Author' GIT_AUTHOR_EMAIL=author@example.test \
    'GIT_COMMITTER_NAME=Env Committer' GIT_COMMITTER_EMAIL=committer@example.test \
    GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z'
  assert_identity 'Env Author' author@example.test 'Env Committer' committer@example.test
  assert_no_arg_matching 'GIT_AUTHOR_DATE=*'
  assert_no_arg_matching 'GIT_COMMITTER_DATE=*'
  echo 'PASS: separate environment overrides without timestamps'
}

test_partial_environment_identity_falls_back_to_config() {
  run_sandbox 'GIT_AUTHOR_NAME=Author Only'
  assert_identity 'Author Only' local@example.test 'Local Name' local@example.test
  echo 'PASS: partial environment override falls back to config'
}

test_author_and_committer_config() {
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
}

test_conditional_include_identity() {
  git config --file "$fixture/included" user.name 'Conditional Name'
  git config --file "$fixture/included" user.email conditional@example.test
  git config --global "includeIf.gitdir:$repo/.git.path" "$fixture/included"
  run_sandbox
  assert_identity 'Conditional Name' conditional@example.test
  echo 'PASS: conditional include'
}

# Later tests launch from the worktree
test_linked_worktree_identity() {
  git -C "$repo" worktree add -q "$fixture/worktree" -b linked
  git config --global "includeIf.gitdir:$repo/.git/worktrees/.path" "$fixture/included"
  repo="$fixture/worktree"
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=worktree
  assert_identity 'Conditional Name' conditional@example.test
  echo 'PASS: conditional identity from a linked worktree'
}

test_dind_permissions() {
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
}

test_dind_switch_matches_environment() {
  local setting options argv
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/dind-args"
  for setting in '' 0 1; do
    for options in '--dind' '--dind --' '--dind --dind'; do
      read -ra argv <<<"$options"
      run_sandbox "DOCKERSAND_DIND=$setting" "${argv[@]}" test env
      cmp -s "$fixture/dind-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--dind differs from DOCKERSAND_DIND=1'
    done
  done
  echo 'PASS: --dind matches the environment opt-in and overrides DOCKERSAND_DIND=0'
}

test_switches_after_app_pass_through() {
  local app_args i
  app_args=(--dind --dbus --gcloud --gh --ssh --egress --ephemeral-tmp --session 'two words' --git-strategy mount --entrypoint /bin/bash --host-gateway '' -p 80)
  run_sandbox test "${app_args[@]}"
  assert_arg --runtime=runsc
  assert_no_arg DOCKERSAND_DIND=1
  [[ "${args[$(( ${#args[@]} - ${#app_args[@]} - 1 ))]}" == test ]] || fail 'app was not preserved'
  for i in "${!app_args[@]}"; do
    [[ "${args[$(( ${#args[@]} - ${#app_args[@]} + i ))]}" == "${app_args[$i]}" ]] ||
      fail 'app arguments were not preserved'
  done
  echo 'PASS: switches after the app are passed through without enabling integrations'
}

# Leaves the sandbox in $sandbox running for the next two tests
test_gcloud_token_forwarding_is_opt_in() {
  run_sandbox
  assert_no_arg_matching 'CLOUDSDK_*'
  assert_no_arg_matching '*/run/secrets/gcloud*'

  rm -f "$FAKE_DOCKER_ARGS_FILE"
  touch "$fixture/hold"
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=0 FAKE_DOCKER_HOLD="$fixture/hold" \
    "$launcher" run --gcloud test env) 2>"$fixture/stderr" &
  sandbox=$!
  wait_for test -s "$FAKE_DOCKER_ARGS_FILE" || { cat "$fixture/stderr" >&2; fail 'launcher did not start'; }
  mapfile -d '' -t args <"$FAKE_DOCKER_ARGS_FILE"
  assert_arg CLOUDSDK_AUTH_ACCESS_TOKEN_FILE=/run/secrets/gcloud/token
  assert_arg CLOUDSDK_CORE_PROJECT=fake-project
  gcloud_token_dir
  [[ -n "$token_dir" && "$(cat "$token_dir/token")" == fake-token ]] || fail 'token not mounted'
  [[ "$(stat -c %a "$(dirname "$token_dir")")" == 700 ]] || fail 'token directory not private'
  assert_arg "type=bind,\"src=$token_dir\",\"dst=/run/secrets/gcloud\",readonly"
  echo 'PASS: opt-in gcloud token forwarding'
}

test_gcloud_token_refreshes_while_running() {
  echo refreshed >"$FAKE_GCLOUD_TOKEN_FILE"
  touch -d '3 minutes ago' "$token_dir/token"
  wait_for grep -qx refreshed "$token_dir/token" || fail 'token not refreshed'
  echo 'PASS: gcloud token refreshes while the sandbox runs'
}

test_gcloud_token_deleted_on_quit() {
  rm "$fixture/hold"
  wait "$sandbox" || fail 'launcher failed'
  wait_for test ! -e "$token_dir" || fail 'token left behind after the sandbox quit'
  echo 'PASS: gcloud token deleted when the sandbox quits'
}

# The launcher's parent execs sleep, which never reaps it, so the exited
# docker run stays a zombie
test_gcloud_token_deleted_when_unreaped() {
  local parent
  rm -f "$FAKE_DOCKER_ARGS_FILE"
  touch "$fixture/hold"
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_GCLOUD=1 FAKE_DOCKER_HOLD="$fixture/hold" \
    exec bash -c '"$0" run test env & exec sleep 60' "$launcher") 2>"$fixture/stderr" &
  parent=$!
  wait_for test -s "$FAKE_DOCKER_ARGS_FILE" || { cat "$fixture/stderr" >&2; fail 'launcher did not start'; }
  mapfile -d '' -t args <"$FAKE_DOCKER_ARGS_FILE"
  gcloud_token_dir
  [[ -n "$token_dir" ]] || fail 'token not mounted'
  rm "$fixture/hold"
  wait_for test ! -e "$token_dir" || fail 'token left behind while the sandbox is a zombie'
  kill "$parent"
  wait "$parent" 2>/dev/null || true
  echo 'PASS: gcloud token deleted when the sandbox quits unreaped'
}

test_gcloud_token_failure_prevents_launch() {
  local dir
  expect_rejected DOCKERSAND_GCLOUD=1 FAKE_GCLOUD_FAIL=1 run test env
  for dir in "$XDG_STATE_HOME"/dockersand/gcloud.*; do
    [[ ! -e "$dir" ]] || fail "token directory left behind: $dir"
  done
  echo 'PASS: gcloud token failure prevents launch'
}

test_gh_token_forwarding_is_opt_in() {
  run_sandbox
  assert_no_arg GH_TOKEN
  [[ "$(<"$FAKE_DOCKER_ARGS_FILE.gh-token")" == unset ]] || fail 'gh token passed without DOCKERSAND_GH'

  run_sandbox DOCKERSAND_GH=1
  assert_arg GH_TOKEN
  assert_no_arg_matching '*gho_fake*'
  [[ "$(<"$FAKE_DOCKER_ARGS_FILE.gh-token")" == gho_fake ]] || fail 'gh token not passed to docker'
  echo 'PASS: opt-in gh token forwarding'
}

test_gh_switch_matches_environment() {
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/gh-args"
  run_sandbox DOCKERSAND_GH=0 --gh test env
  cmp -s "$fixture/gh-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--gh differs from DOCKERSAND_GH=1'
  [[ "$(<"$FAKE_DOCKER_ARGS_FILE.gh-token")" == gho_fake ]] || fail '--gh did not pass the token to Docker'
  echo 'PASS: --gh matches the environment opt-in and overrides DOCKERSAND_GH=0'
}

test_gh_token_failure_prevents_launch() {
  expect_rejected DOCKERSAND_GH=1 FAKE_GH_FAIL=1 run test env
  echo 'PASS: gh token failure prevents launch'
}

test_missing_identity_allows_launch() {
  : >"$GIT_CONFIG_GLOBAL"
  git config --global user.useConfigOnly true
  run_sandbox
  assert_no_arg_matching 'GIT_AUTHOR_*=*'
  assert_no_arg_matching 'GIT_COMMITTER_*=*'
  echo 'PASS: missing identity does not prevent launch'
}

# Later tests launch from the plain directory
test_identity_outside_git_repository() {
  repo="$fixture/plain"
  mkdir -p "$repo"
  git config --global user.name 'Directory User'
  git config --global user.email directory@example.test
  run_sandbox
  assert_identity 'Directory User' directory@example.test
  echo 'PASS: identity outside a git repository'
}

# Docker splits -v on ':' and parses --mount as CSV, so odd names need quoting.
# Later tests launch from this repository.
test_mount_quotes_odd_project_directory() {
  weird='we:ird,na"me'
  weird_q='we:ird,na""me'
  repo="$fixture/$weird"
  make_repo "$repo"
  real="$(realpath "$repo")"
  real_q="${real//\"/\"\"}"

  run_sandbox
  assert_no_arg_matching '-v*'
  assert_arg --mount
  assert_arg "type=bind,\"src=$real_q\",\"dst=/home/work/repos/$weird_q\""
  echo 'PASS: mount strategy quotes a project directory with : , and "'
}

test_clone_quotes_odd_state_directory() {
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=weird
  assert_no_arg_matching '-v*'
  checkout_name="$weird-$(printf %s "$real" | sha256sum | cut -c1-8)"
  assert_arg "type=bind,\"src=${XDG_STATE_HOME//\"/\"\"}/dockersand/sessions/${checkout_name//\"/\"\"}/weird/repos\",\"dst=/home/work/repos\""
  assert_arg "type=bind,\"src=${XDG_STATE_HOME//\"/\"\"}/dockersand/sessions/${checkout_name//\"/\"\"}/weird/tmp\",\"dst=/tmp\""
  echo 'PASS: clone strategy quotes a state directory with : , and "'
}

test_ssh_mounts_quoted_and_known_hosts_read_only() {
  mkdir -p "$fixture/home/.ssh"
  touch "$fixture/home/.ssh/known_hosts"
  run_sandbox DOCKERSAND_SSH=1 "HOME=$fixture/home" "SSH_AUTH_SOCK=$fixture/ssh:agent.sock"
  assert_no_arg_matching '-v*'
  assert_arg "type=bind,\"src=$fixture/ssh:agent.sock\",\"dst=/run/dockersand/ssh-agent.sock\""
  assert_arg "type=bind,\"src=$fixture/home/.ssh/known_hosts\",\"dst=/home/work/.ssh/known_hosts\",readonly"
  echo 'PASS: SSH mounts are quoted and known_hosts is read-only'
}

test_ssh_switch_matches_environment() {
  cp "$FAKE_DOCKER_ARGS_FILE" "$fixture/ssh-args"
  run_sandbox DOCKERSAND_SSH=0 "HOME=$fixture/home" "SSH_AUTH_SOCK=$fixture/ssh:agent.sock" --ssh test env
  cmp -s "$fixture/ssh-args" "$FAKE_DOCKER_ARGS_FILE" || fail '--ssh differs from DOCKERSAND_SSH=1'
  echo 'PASS: --ssh matches the environment opt-in and overrides DOCKERSAND_SSH=0'
}

test_repository_identity_without_global_config
test_global_identity_and_default_isolation
test_repository_identity_overrides_global
test_clone_uses_host_checkout_identity
test_clone_session_keeps_repos_and_tmp_together
test_ephemeral_tmp_skips_session_tmp
test_session_switch_resumes_clone
test_invalid_sessions_rejected
test_valued_switches_need_values
test_entrypoint_and_host_gateway_switches
test_published_ports_default_to_loopback
test_publish_switches_override_environment
test_invalid_ports_rejected
test_egress_switch_needs_running_proxy
test_run_passes_subcommand_names_through
test_bare_apps_and_unknown_subcommands_print_usage
test_registry_path_images_skip_repo_hooks
test_path_hooks_run_for_bare_apps
test_option_like_app_names_rejected
test_environment_identity_without_timestamps
test_partial_environment_identity_falls_back_to_config
test_author_and_committer_config
test_conditional_include_identity
test_linked_worktree_identity
test_dind_permissions
test_dind_switch_matches_environment
test_switches_after_app_pass_through
test_gcloud_token_forwarding_is_opt_in
test_gcloud_token_refreshes_while_running
test_gcloud_token_deleted_on_quit
test_gcloud_token_deleted_when_unreaped
test_gcloud_token_failure_prevents_launch
test_gh_token_forwarding_is_opt_in
test_gh_switch_matches_environment
test_gh_token_failure_prevents_launch
test_missing_identity_allows_launch
test_identity_outside_git_repository
test_mount_quotes_odd_project_directory
test_clone_quotes_odd_state_directory
test_ssh_mounts_quoted_and_known_hosts_read_only
test_ssh_switch_matches_environment
