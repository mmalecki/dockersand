#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

install_fake_docker
make_repo "$repo"
printf '.env\n*.key\nsecrets/\n' >"$repo/.gitignore"
mkdir "$repo/config"
echo committed >"$repo/config/settings"
ln -s settings "$repo/config/link"
git -C "$repo" add .gitignore config
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm 'Ignore secrets'
checkout="repo-$(printf %s "$(realpath "$repo")" | sha256sum | cut -c1-8)"
clone="$XDG_STATE_HOME/dockersand/sessions/$checkout/copied/repos/repo"

# The tests below run in the order they're called at the end of this file,
# and later ones resume the session the first one makes.

# Launches session copied with "[run arguments]", from $repo
run_copied() {
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied "$@"
}

# Fails unless a new session refuses --cp "$1", without leaving a session
# behind, with diagnostic $2
expect_copy_rejected() {
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=rejected run --cp "$1" test env
  grep -Fq -- "$2" "$fixture/stderr" || { cat "$fixture/stderr" >&2; fail "missing diagnostic for --cp $1: $2"; }
  [[ ! -e "$XDG_STATE_HOME/dockersand/sessions/$checkout/rejected" ]] || fail "--cp $1 left a session behind"
}

# Fails unless file $1 in the checkout and in the clone match, with mode and mtime
assert_copied() {
  cmp -s "$repo/$1" "$clone/$1" || fail "$1 not copied"
  [[ ! -L "$clone/$1" ]] || fail "$1 copied as a link"
  [[ "$(stat -L -c '%a %Y' "$repo/$1")" == "$(stat -c '%a %Y' "$clone/$1")" ]] || fail "$1 lost its mode or mtime"
}

test_copies_into_a_new_session() {
  echo SECRET=1 >"$repo/.env"
  chmod 600 "$repo/.env"
  touch -d '2020-01-02 03:04:05' "$repo/.env"
  mkdir -p "$repo/secrets/deep"
  echo key >"$repo/secrets/deep/api.key"
  run_copied --cp .env --cp secrets/deep/api.key test env
  assert_copied .env
  assert_copied secrets/deep/api.key
  [[ -z "$(find "$clone" -name '.dockersand-cp.*')" ]] || fail 'a temporary copy was left behind'
  echo 'PASS: --cp copies files into a new session, making missing directories'
}

# --cp makes the untracked directory, so the sandbox starts in it
test_relative_to_an_untracked_directory() {
  local top="$repo"
  rm -r "$clone/secrets"
  repo="$top/secrets/deep"
  run_copied --cp api.key --cp ../../.env test env
  repo="$top"
  assert_copied secrets/deep/api.key
  assert_copied .env
  assert_arg /home/work/repos/repo/secrets/deep/
  echo 'PASS: --cp paths are relative to the launch directory, which the copy can make'
}

test_resuming_replaces_only_with_the_switch() {
  local without
  echo edited >"$clone/.env"
  run_copied test env
  [[ "$(<"$clone/.env")" == edited ]] || fail 'resuming without --cp replaced the copy'
  without=("${args[@]}")
  run_copied --cp .env test env
  assert_copied .env
  [[ "${args[*]}" == "${without[*]}" ]] || fail '--cp changed the docker run arguments'
  echo 'PASS: resuming with --cp replaces the copy, and without it keeps the sandbox changes'
}

test_tracked_and_linked_files() {
  echo uncommitted >"$repo/config/settings"
  echo linked >"$fixture/target"
  ln -s "$fixture/target" "$repo/linked.key"
  run_copied --cp config/settings --cp linked.key test env
  assert_copied config/settings
  assert_copied linked.key
  git -C "$repo" checkout -q config/settings
  echo 'PASS: --cp copies over tracked files, and follows links to files'
}

test_planted_links_are_not_followed() {
  echo victim >"$fixture/victim"
  rm "$clone/.env"
  ln -s "$fixture/victim" "$clone/.env"
  run_copied --cp .env test env
  [[ "$(<"$fixture/victim")" == victim ]] || fail 'the copy wrote through a planted file link'
  assert_copied .env

  rm "$clone/.env"
  ln "$fixture/victim" "$clone/.env"
  run_copied --cp .env test env
  [[ "$(<"$fixture/victim")" == victim ]] || fail 'the copy wrote through a planted hard link'
  assert_copied .env

  mkdir "$fixture/victim-dir"
  rm -r "$clone/secrets"
  ln -s "$fixture/victim-dir" "$clone/secrets"
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied run --cp secrets/deep/api.key test env
  grep -Fq 'repo/secrets is not a directory in the clone' "$fixture/stderr" || fail 'missing planted directory diagnostic'
  [[ -z "$(ls -A "$fixture/victim-dir")" ]] || fail 'the copy went through a planted directory link'
  rm "$clone/secrets"

  mv "$clone" "$clone.real"
  ln -s "$clone.real" "$clone"
  echo edited >"$clone.real/.env"
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied run --cp .env test env
  grep -Fq 'repo is not a directory in the clone' "$fixture/stderr" || fail 'missing planted clone diagnostic'
  [[ "$(<"$clone.real/.env")" == edited ]] || fail 'the copy went through a planted clone link'
  rm "$clone"
  mv "$clone.real" "$clone"
  echo 'PASS: --cp replaces a planted link to a file, and refuses one to a directory or the clone'
}

test_files_it_cannot_copy_are_rejected() {
  local option argv
  expect_copy_rejected missing 'no such file'
  expect_copy_rejected secrets 'not a regular file'
  ln -s missing "$repo/broken.key"
  expect_copy_rejected broken.key 'no such file'
  echo outside >"$fixture/outside"
  expect_copy_rejected ../outside 'outside the checkout'
  mkdir "$fixture/elsewhere"
  echo elsewhere >"$fixture/elsewhere/file.key"
  ln -s "$fixture/elsewhere" "$repo/elsewhere"
  expect_copy_rejected elsewhere/file.key 'outside the checkout'
  expect_copy_rejected .git/config 'inside .git'
  expect_rejected run --cp .env test env
  grep -Fq -- '--cp needs DOCKERSAND_GIT_STRATEGY=clone' "$fixture/stderr" || fail 'missing mount mode diagnostic'
  for option in '--cp' '--cp --ssh test'; do
    read -ra argv <<<"$option"
    expect_rejected DOCKERSAND_GIT_STRATEGY=clone run "${argv[@]}"
    grep -Fq -- '--cp requires a value' "$fixture/stderr" || fail "missing diagnostic for $option"
  done
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone run --cp '' test
  echo 'PASS: --cp rejects missing files, directories, files outside the checkout or in .git, and mount mode'
}

test_files_the_sandbox_could_commit_are_rejected() {
  echo notes >"$repo/notes.txt"
  expect_copy_rejected notes.txt 'not ignored by the repository'
  echo notes.txt >>"$repo/.git/info/exclude"
  expect_copy_rejected notes.txt 'not ignored by the repository'
  echo notes.txt >"$fixture/excludes"
  git config --global core.excludesFile "$fixture/excludes"
  expect_copy_rejected notes.txt 'not ignored by the repository'
  # A tracked link would land as a file, and a link in place of a tracked file
  # would put its target's content there
  expect_copy_rejected config/link 'not ignored by the repository'
  rm "$repo/config/settings"
  ln -s "$fixture/target" "$repo/config/settings"
  expect_copy_rejected config/settings 'not ignored by the repository'
  git -C "$repo" checkout -q config/settings

  echo notes.txt >>"$repo/.gitignore"
  expect_copy_rejected notes.txt 'commit .gitignore first'
  git -C "$repo" checkout -q .gitignore
  mkdir "$repo/docs"
  echo draft >"$repo/docs/draft.txt"
  echo '*.txt' >"$repo/docs/.gitignore"
  expect_copy_rejected docs/draft.txt 'commit docs/.gitignore first'
  git -C "$repo" add docs/.gitignore
  expect_copy_rejected docs/draft.txt 'commit docs/.gitignore first'
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.test commit -qm 'Ignore drafts'
  run_sandbox DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=drafts --cp docs/draft.txt test env
  cmp -s "$repo/docs/draft.txt" "${clone%/copied/*}/drafts/repos/repo/docs/draft.txt" || fail 'draft not copied'
  echo 'PASS: --cp copies an untracked file into a new clone only if the committed .gitignore files ignore it'
}

# The session copied predates docs/.gitignore
test_resumed_clones_must_ignore_files_too() {
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied run --cp docs/draft.txt test env
  grep -Fq "docs/.gitignore differs in the session's clone" "$fixture/stderr" || fail 'missing clone .gitignore diagnostic'
  [[ ! -e "$clone/docs/draft.txt" ]] || fail 'draft copied into a clone that does not ignore it'
  cp "$clone/.gitignore" "$fixture/clone-gitignore"
  echo '!.env' >>"$clone/.gitignore"
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied run --cp .env test env
  grep -Fq ".gitignore differs in the session's clone" "$fixture/stderr" || fail 'missing changed .gitignore diagnostic'
  rm "$clone/.gitignore"
  ln -s "$repo/.gitignore" "$clone/.gitignore"
  expect_rejected DOCKERSAND_GIT_STRATEGY=clone DOCKERSAND_SESSION=copied run --cp .env test env
  rm "$clone/.gitignore"
  cp "$fixture/clone-gitignore" "$clone/.gitignore"
  run_copied --cp .env test env
  echo "PASS: --cp into a resumed session needs the clone's .gitignore files to match"
}

test_copies_into_a_new_session
test_relative_to_an_untracked_directory
test_resuming_replaces_only_with_the_switch
test_tracked_and_linked_files
test_planted_links_are_not_followed
test_files_it_cannot_copy_are_rejected
test_files_the_sandbox_could_commit_are_rejected
test_resumed_clones_must_ignore_files_too
