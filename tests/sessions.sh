#!/usr/bin/env bash
set -euo pipefail

launcher="$(cd "$(dirname "$0")/.." && pwd)/dockersand"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture/home" XDG_STATE_HOME="$fixture/state with spaces"
export MOCK_DOCKER_ROOT="$fixture/docker"
unset DOCKERSAND_GIT_STRATEGY DOCKERSAND_SESSION_NAME
mkdir -p "$HOME" "$fixture/bin" "$MOCK_DOCKER_ROOT"
root="$XDG_STATE_HOME/dockersand/repos"
touch "$MOCK_DOCKER_ROOT/names" "$MOCK_DOCKER_ROOT/calls"

cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_DOCKER_ROOT/calls"
case "$1 $2" in
  'container ls')
    [[ ! -e "$MOCK_DOCKER_ROOT/unavailable" ]] || exit 1
    cat "$MOCK_DOCKER_ROOT/names"
    ;;
  'container inspect')
    [[ "$3" == --format ]] || exit 1
    # Check that the launcher requests the resolved command, with escaping.
    [[ "$4" == *'.State.Status'* && "$4" == *'printf "%q" .Path'* &&
       "$4" == *'range .Args'* && "$4" == *'printf "%q" .'* ]] || exit 1
    if [[ -e "$MOCK_DOCKER_ROOT/disappear" ]]; then
      : >"$MOCK_DOCKER_ROOT/names"
      exit 1
    fi
    if [[ -e "$MOCK_DOCKER_ROOT/fail-after-list" ]]; then
      touch "$MOCK_DOCKER_ROOT/unavailable"
      exit 1
    fi
    cat "$MOCK_DOCKER_ROOT/${!#}.inspect"
    ;;
  *) echo "unexpected Docker call: $*" >&2; exit 1 ;;
esac
EOF
# Listing must not invoke Git, hooks, or authentication integrations.
for executable in git gcloud gh dockersand-args-sessions; do
  cat >"$fixture/bin/$executable" <<'EOF'
#!/usr/bin/env bash
touch "$MOCK_DOCKER_ROOT/unexpected-launch-setup"
exit 1
EOF
done
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
run_list() {
  list_exit=0
  (cd "$HOME" && "$launcher" sessions list) >"$fixture/stdout" 2>"$fixture/stderr" || list_exit=$?
}
assert_row() {
  local row
  printf -v row '%-20s %-12s %q\t%s\t%s' "$1" "$2" "$3" "$4" "$5"
  grep -Fxq -- "$row" "$fixture/stdout" || fail "missing row: $row"
}
assert_success() {
  [[ "$list_exit" == 0 && ! -s "$fixture/stderr" ]] || { cat "$fixture/stderr" >&2; fail 'listing failed'; }
  [[ ! -e "$MOCK_DOCKER_ROOT/unexpected-launch-setup" ]] || fail 'listing ran launch setup'
}

run_list
assert_success
[[ "$(wc -l <"$fixture/stdout")" == 1 ]] || fail 'empty state should print only a header'
printf -v header '%-20s %-12s %s\t%s\t%s' 'SESSION ID' STATE 'SANDBOX DIRECTORY' CONTAINER COMMAND
grep -Fxq -- "$header" "$fixture/stdout" || fail "missing header: $header"
[[ ! -s "$MOCK_DOCKER_ROOT/calls" && ! -e "$XDG_STATE_HOME" ]] || fail 'empty listing accessed Docker or created state'
echo 'PASS: empty listing runs anywhere without launch setup or state writes'

mkdir -p "$root/project-a1b2c3d4/shared/project" "$root/other-12345678/shared/other"
mkdir -p "$root/project-a1b2c3d4/.hidden/project"
mkdir -p "$fixture/outside/injected" "$root/project-a1b2c3d4/bad name"
ln -s "$fixture/outside" "$root/linked-12345678"
ln -s "$fixture/outside" "$root/project-a1b2c3d4/linked"
# Deeper worktree directories must not become separate sessions.
mkdir -p "$root/project-a1b2c3d4/shared/worktree/nested"
run_list
assert_success
assert_row shared idle "$root/project-a1b2c3d4/shared" — —
assert_row shared idle "$root/other-12345678/shared" — —
assert_row .hidden idle "$root/project-a1b2c3d4/.hidden" — —
[[ "$(wc -l <"$fixture/stdout")" == 4 ]] || fail 'unexpected session directories'
echo 'PASS: saved sessions across checkouts, hidden names, spaces, and ignored symlinks'

name=dockersand-project-a1b2c3d4-shared
printf '%s\n' unrelated-container "$name" >"$MOCK_DOCKER_ROOT/names"
printf 'shared\n%s\nrunning\n"bash" "-lc" "echo hello world; echo \\"quoted\\""\n' "$root/project-a1b2c3d4/shared" >"$MOCK_DOCKER_ROOT/$name.inspect"
run_list
assert_success
assert_row shared running "$root/project-a1b2c3d4/shared" "$name" '"bash" "-lc" "echo hello world; echo \"quoted\""'
echo 'PASS: running containers show their name, resolved executable and quoted arguments'

printf 'shared\n%s\npaused\n"codex" "--help"\n' "$root/project-a1b2c3d4/shared" >"$MOCK_DOCKER_ROOT/$name.inspect"
run_list
assert_success
assert_row shared paused "$root/project-a1b2c3d4/shared" "$name" '"codex" "--help"'
echo 'PASS: sessions use Docker lifecycle states'

printf 'shared\n%s\nrunning\n"wrong-command"\n' "$fixture/different-state/shared" >"$MOCK_DOCKER_ROOT/$name.inspect"
run_list
assert_success
assert_row shared idle "$root/project-a1b2c3d4/shared" — —
echo 'PASS: containers labelled for another state directory are excluded'

printf '\n\nrunning\n"unlabelled-command"\n' >"$MOCK_DOCKER_ROOT/$name.inspect"
run_list
assert_success
assert_row shared idle "$root/project-a1b2c3d4/shared" — —
echo 'PASS: unlabelled containers are excluded'

printf 'shared\n%s\nexited\n"old-command"\n' "$root/project-a1b2c3d4/shared" >"$MOCK_DOCKER_ROOT/$name.inspect"
run_list
assert_success
assert_row shared exited "$root/project-a1b2c3d4/shared" "$name" —
echo 'PASS: stopped containers show their name but no running command'

touch "$MOCK_DOCKER_ROOT/disappear"
run_list
assert_success
assert_row shared idle "$root/project-a1b2c3d4/shared" — —
rm "$MOCK_DOCKER_ROOT/disappear"
echo 'PASS: containers removed between listing and inspection become idle'

printf '%s\n' "$name" >"$MOCK_DOCKER_ROOT/names"
rm "$MOCK_DOCKER_ROOT/$name.inspect"
run_list
[[ "$list_exit" == 1 && -s "$fixture/stderr" ]] || fail 'inspect failure was hidden'
assert_row shared unknown "$root/project-a1b2c3d4/shared" — —
echo 'PASS: persistent inspection failures produce unknown status and fail'

touch "$MOCK_DOCKER_ROOT/fail-after-list"
run_list
[[ "$list_exit" == 1 && -s "$fixture/stderr" ]] || fail 'daemon loss was hidden'
assert_row shared unknown "$root/project-a1b2c3d4/shared" — —
echo 'PASS: daemon loss during inspection produces unknown status'

run_list
[[ "$list_exit" == 1 && -s "$fixture/stderr" ]] || fail 'unavailable Docker was hidden'
assert_row shared unknown "$root/other-12345678/shared" — —
assert_row .hidden unknown "$root/project-a1b2c3d4/.hidden" — —
echo 'PASS: unavailable Docker still lists directories with unknown status'

# Unset XDG_STATE_HOME to exercise the default state location.
mkdir -p "$HOME/.local/state/dockersand/repos/default-12345678/example"
unset XDG_STATE_HOME
run_list
[[ "$list_exit" == 1 ]] || fail 'expected unavailable Docker'
assert_row example unknown "$HOME/.local/state/dockersand/repos/default-12345678/example" — —
echo 'PASS: default state location'

for arguments in 'sessions' 'sessions unknown' 'sessions list extra' '--sessions list'; do
  read -ra argv <<<"$arguments"
  if "$launcher" "${argv[@]}" >"$fixture/stdout" 2>"$fixture/stderr"; then
    fail "accepted invalid management arguments: $arguments"
  fi
  grep -Fq 'dockersand sessions list' "$fixture/stderr" || fail 'missing management usage'
done
[[ ! -e "$MOCK_DOCKER_ROOT/unexpected-launch-setup" ]] || fail 'management ran launch setup'
echo 'PASS: invalid management commands fail before launch setup'
