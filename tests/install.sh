#!/usr/bin/env bash
set -euo pipefail

src="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

scripts=(dockersand dockersand-args-all-agents dockersand-args-claude dockersand-args-codex
  dockersand-args-opencode dockersand-args-pi)

# DESTDIR stages under the default prefix; spaces must survive
destdir="$fixture/dest dir"
make -s -C "$src" install DESTDIR="$destdir"
for script in "${scripts[@]}"; do
  [[ -x "$destdir/usr/local/bin/$script" ]] || fail "$script not installed under DESTDIR"
  cmp -s "$src/$script" "$destdir/usr/local/bin/$script" || fail "$script installed with different contents"
done
echo 'PASS: install stages every script under DESTDIR'

make -s -C "$src" uninstall DESTDIR="$destdir"
[[ -z "$(ls -A "$destdir/usr/local/bin")" ]] || fail 'uninstall left files behind'
echo 'PASS: uninstall removes every installed script'

make -s -C "$src" install PREFIX="$fixture/prefix"
for script in "${scripts[@]}"; do
  [[ -x "$fixture/prefix/bin/$script" ]] || fail "$script not installed under PREFIX"
done
echo 'PASS: install honours PREFIX'

PATH="$fixture/prefix/bin:$PATH" dockersand --help >/dev/null || fail 'installed launcher does not run'
echo 'PASS: installed launcher runs'
