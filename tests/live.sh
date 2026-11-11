#!/usr/bin/env bash
# Launches real sandboxes: needs Docker with runsc registered as a runtime,
# configured with --host-uds=open for the SSH agent test.
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

image="dockersand-live-$$"
# Until the cleanup below runs
held_pids=()
agent_pid=""
cleanup() {
  local id dir pid
  # Only this run's sessions, not any others on the same daemon
  while read -r id dir; do
    [[ "$dir" != "$real_fixture"/* ]] || docker rm -f "$id" >/dev/null 2>&1 || true
  done < <(docker ps --all --filter label=io.dockersand.directory \
    --format '{{.ID}} {{.Label "io.dockersand.directory"}}' 2>/dev/null)
  for pid in "${held_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  [[ -z "$agent_pid" ]] || kill "$agent_pid" 2>/dev/null || true
  docker image rm "$image" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
real_fixture="$(realpath "$fixture")"
unset SSH_AUTH_SOCK SSH_AGENT_PID GH_TOKEN

docker info --format '{{json .Runtimes}}' | grep -q '"runsc"' ||
  fail 'Docker has no runsc runtime; install gVisor first'

# What the sandbox writes must belong to the host user. Rootless Docker maps
# the host user to root in the container.
work_uid="$(id -u)"
if docker info --format '{{json .SecurityOptions}}' | grep -q name=rootless; then
  work_uid=0
fi
docker build -t "$image" --build-arg WORK_UID="$work_uid" - >"$fixture/build.log" 2>&1 <<'EOF' ||
FROM alpine:3.22
ARG WORK_UID
RUN apk add --no-cache busybox-extras git openssh-client \
  && if [ "$WORK_UID" != 0 ]; then adduser -D -u "$WORK_UID" work; fi
USER $WORK_UID
EOF
  { cat "$fixture/build.log" >&2; fail 'test image build failed'; }

git config --global user.name 'Live Test'
git config --global user.email live@example.test
make_repo "$repo"
echo original >"$repo/tracked"
git -C "$repo" add tracked
git -C "$repo" commit -qm 'Add a tracked file'
branch="$(git -C "$repo" symbolic-ref --short HEAD)"
checkout="repo-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
# Holds a sandbox open until release creates /tmp/go, the session's on the host
hold='until [ -e /tmp/go ]; do sleep 0.2; done'

# Launches from the current directory with "[NAME=value...] [run arguments]",
# in mount mode unless the assignments say otherwise. Prints the sandbox's
# output; the launcher's own goes to $fixture/stderr.
sandbox() {
  split_env "$@"
  env "${env_args[@]}" "$launcher" run "${cli_args[@]}" </dev/null 2>"$fixture/stderr" ||
    { cat "$fixture/stderr" >&2; fail "launcher failed: $*"; }
}

session_dir() {
  printf '%s/dockersand/sessions/%s/%s' "$XDG_STATE_HOME" "$checkout" "$1"
}

# Starts clone session $1 of $repo in the background, running "[run arguments]"
hold_session() {
  local session="$1"
  shift
  (cd "$repo" && DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION="$session" \
    "$launcher" run "$@") </dev/null >/dev/null 2>"$fixture/$session.stderr" &
  held_pids+=("$!")
}

# Ends held session $1, and waits for its launcher to exit
release() {
  touch "$(session_dir "$1")/tmp/go"
  wait "${held_pids[-1]}" || { cat "$fixture/$1.stderr" >&2; fail "session $1 failed"; }
  unset 'held_pids[-1]'
}

# Whether sessions list shows session $1 in state $2
session_is() {
  [[ "$("$launcher" sessions list | awk -v session="$1" '$1 == session { print $2 }')" == "$2" ]]
}

# Whether held session $1 serves the project on its published port 8080
serving() {
  local address
  address="$(docker port "dockersand-$checkout-$1" 8080 2>/dev/null)" &&
    curl -fso /dev/null "http://$address/tracked"
}

test_mount_mode_shows_only_the_project() {
  local marker found
  marker="dockersand-live-marker-$RANDOM$RANDOM"
  echo "$marker" >"$repo/inside"
  echo "$marker" >"$fixture/outside"
  mkdir "$repo/sub"
  cd "$repo/sub"
  [[ "$(sandbox "$image" pwd)" == /home/work/repos/repo/sub ]] || fail 'not in the project subdirectory'
  [[ "$(sandbox "$image" ls -A /home/work/repos)" == repo ]] || fail 'more than the project under repos'
  sandbox "$image" sh -c 'echo written >from-sandbox'
  [[ "$(stat -c %u from-sandbox)" == "$(id -u)" ]] || fail 'the sandbox wrote as another host user'
  found="$(sandbox "$image" sh -c 'find / -path /proc -prune -o -path /sys -prune -o \
    -type f -exec grep -lF "$0" {} + 2>/dev/null; true' "$marker")"
  [[ "$found" == /home/work/repos/repo/inside ]] || fail "marker found at: ${found:-nowhere}"
  cd "$repo"
  echo 'PASS: mount mode shows the project, from the launch subdirectory, and nothing else of the host'
}

test_clone_mode_leaves_the_checkout_alone() {
  local head clone
  head="$(git rev-parse HEAD)"
  sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=live "$image" sh -ec '
    echo changed >tracked
    git commit -qam "Change from the sandbox"
    printf "#!/bin/sh\n" >.git/hooks/post-checkout
    echo scratch >/tmp/scratch' >/dev/null
  [[ "$(git rev-parse HEAD)" == "$head" ]] || fail 'the checkout moved'
  [[ "$(<tracked)" == original ]] || fail 'the checkout was changed'
  [[ ! -e .git/hooks/post-checkout ]] || fail 'the sandbox planted a hook in the checkout'
  clone="$(session_dir live)/repos/repo"
  git fetch -q "$clone" "$branch"
  [[ "$(git log -1 --format=%s FETCH_HEAD)" == 'Change from the sandbox' ]] || fail 'commit not fetched from the clone'
  echo 'PASS: clone mode commits in its own clone, which the host can fetch from'
}

test_clone_sessions_resume_with_their_tmp() {
  local out
  out="$(sandbox DOCKERSAND_GIT_STRATEGY=clone --session live "$image" sh -c 'git log -1 --format=%s; cat /tmp/scratch')"
  [[ "$out" == $'Change from the sandbox\nscratch' ]] || fail "resumed session differs: $out"
  out="$(sandbox DOCKERSAND_GIT_STRATEGY=clone --session live --ephemeral-tmp "$image" sh -c 'git log -1 --format=%s; ls -A /tmp')"
  [[ "$out" == 'Change from the sandbox' ]] || fail "ephemeral /tmp session differs: $out"
  echo 'PASS: resumed sessions keep their clone, and their /tmp unless --ephemeral-tmp'
}

test_sessions_list_follows_a_running_session() {
  hold_session held "$image" sh -c "$hold"
  wait_for session_is held running ||
    { cat "$fixture/held.stderr" >&2; fail 'held session not listed as running'; }
  [[ "$("$launcher" sessions list)" == *"\"sh\" \"-c\" \"$hold\""* ]] || fail 'running command not listed'
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=held run "$image" true
  grep -Fq 'session held is already running' "$fixture/stderr" || fail 'missing already running diagnostic'
  release held
  wait_for session_is held idle || fail 'released session not listed as idle'
  echo 'PASS: sessions list follows a running session, which cannot run twice'
}

test_published_ports_stay_on_loopback() {
  local address host_ip port
  hold_session ports -p 8080 "$image" sh -c "httpd -p 8080 -h /home/work/repos/repo && $hold"
  wait_for serving ports ||
    { cat "$fixture/ports.stderr" >&2; fail 'published port not reachable on loopback'; }
  address="$(docker port "dockersand-$checkout-ports" 8080)"
  [[ "$address" == 127.0.0.1:* ]] || fail "published on $address"
  port="${address##*:}"
  host_ip="$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  [[ -n "$host_ip" ]] || fail 'no non-loopback host address to try'
  ! curl -fso /dev/null --max-time 5 "http://$host_ip:$port/tracked" || fail "reachable on $host_ip"
  release ports
  echo 'PASS: published ports are reachable on loopback only'
}

test_ssh_agent_and_known_hosts() {
  local out
  mkdir -p "$fixture/home/.ssh"
  echo 'example.test ssh-ed25519 not-a-real-key' >"$fixture/home/.ssh/known_hosts"
  ssh-keygen -q -t ed25519 -N '' -C live-test -f "$fixture/key"
  ssh-agent -D -a "$fixture/agent.sock" >/dev/null 2>&1 &
  agent_pid=$!
  wait_for test -S "$fixture/agent.sock" || fail 'ssh-agent did not start'
  SSH_AUTH_SOCK="$fixture/agent.sock" ssh-add -q "$fixture/key"
  out="$(sandbox DOCKERSAND_SSH=1 "HOME=$fixture/home" "SSH_AUTH_SOCK=$fixture/agent.sock" "$image" ssh-add -l)"
  [[ "$out" == "$(SSH_AUTH_SOCK="$fixture/agent.sock" ssh-add -l)" ]] || fail "agent keys differ: $out"
  out="$(sandbox DOCKERSAND_SSH=1 "HOME=$fixture/home" "SSH_AUTH_SOCK=$fixture/agent.sock" "$image" \
    sh -c 'cat /home/work/.ssh/known_hosts; if echo >>/home/work/.ssh/known_hosts; then echo writable; fi')"
  [[ "$out" == "$(<"$fixture/home/.ssh/known_hosts")" ]] || fail "known_hosts not read-only: $out"
  echo 'PASS: --ssh forwards the agent, and known_hosts read-only'
}

# Docker splits -v on ':' and parses --mount as CSV
test_odd_project_paths_are_mounted() {
  local weird='we:ird,na"me' out
  make_repo "$fixture/$weird"
  cd "$fixture/$weird"
  [[ "$(sandbox "$image" pwd)" == "/home/work/repos/$weird" ]] || fail 'mount mode missed the odd path'
  out="$(sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=weird "$image" sh -c 'pwd; git rev-parse --is-inside-work-tree')"
  [[ "$out" == "/home/work/repos/$weird"$'\ntrue' ]] || fail "clone mode missed the odd path: $out"
  cd "$repo"
  echo 'PASS: projects with : , and " in their path launch in both strategies'
}

# Last, so that a local run on runc, aliased as runsc, checks everything else
test_sandbox_runs_on_gvisor() {
  local kernel
  kernel="$(sandbox "$image" uname -r)"
  [[ "$kernel" != "$(uname -r)" ]] || fail 'the sandbox runs on the host kernel'
  echo "PASS: the sandbox runs on its own kernel ($kernel), not the host's"
}

cd "$repo"
test_mount_mode_shows_only_the_project
test_clone_mode_leaves_the_checkout_alone
test_clone_sessions_resume_with_their_tmp
test_sessions_list_follows_a_running_session
test_published_ports_stay_on_loopback
test_ssh_agent_and_known_hosts
test_odd_project_paths_are_mounted
test_sandbox_runs_on_gvisor
