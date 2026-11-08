#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

export HOME="$fixture/home"
mkdir -p "$HOME"
install_fake_docker
make_repo "$repo"

# Separate fetch and push protocols/destinations.
git -C "$repo" remote add origin https://upstream.example.test/project.git
git -C "$repo" remote set-url --push origin git@fork.example.test:project.git
# Multiple URLs, with the implicit push fallback when no pushurl is configured.
git -C "$repo" remote add fallback git@example.test:first.git
git -C "$repo" remote set-url --add fallback git@example.test:second.git
# Host URL rewrites must still work when the sandbox has no host gitconfig.
git config --global url.https://fetch.example.test/.insteadOf review:
git config --global url.ssh://git@push.example.test/.pushInsteadOf https://rewrite.example.test/
git -C "$repo" remote add alias review:project.git
git -C "$repo" remote add rewritten https://rewrite.example.test/project.git
# Two real push destinations, distinct from both fetch URLs.
for destination in 'push one' 'push two'; do
  git init -q --bare "$fixture/$destination"
done
git -C "$repo" remote add mirrors https://fetch.example.test/first.git
git -C "$repo" remote set-url --add mirrors https://fetch.example.test/second.git
git -C "$repo" remote set-url --add --push mirrors "$fixture/push one"
git -C "$repo" remote set-url --add --push mirrors "$fixture/push two"

run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=remotes test
checkout="repo-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
clone="$XDG_STATE_HOME/dockersand/sessions/$checkout/remotes/repos/repo"
# This clone is a test fixture, not an agent-controlled saved session.
clone_git() { GIT_CONFIG_GLOBAL=/dev/null git -C "$clone" "$@"; }

for remote in origin fallback alias rewritten mirrors; do
  [[ "$(git -C "$repo" remote get-url --all "$remote")" == \
     "$(clone_git remote get-url --all "$remote")" ]] || fail "fetch URLs changed for $remote"
  [[ "$(git -C "$repo" remote get-url --push --all "$remote")" == \
     "$(clone_git remote get-url --push --all "$remote")" ]] || fail "push URLs changed for $remote"
  echo "PASS: $remote preserves all effective fetch and push URLs without host gitconfig"
done

clone_git push -q mirrors HEAD:refs/heads/probe
expected="$(git -C "$repo" rev-parse HEAD)"
for destination in 'push one' 'push two'; do
  [[ "$(git --git-dir="$fixture/$destination" rev-parse refs/heads/probe)" == "$expected" ]] ||
    fail "commit did not reach $destination"
done
echo 'PASS: a push from the clone reaches both configured destinations'
