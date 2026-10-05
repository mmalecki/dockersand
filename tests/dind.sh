#!/usr/bin/env bash
# Run inside an agents-based image launched with DOCKERSAND_DIND=1.
set -euo pipefail

[[ "$(id -u)" != 0 ]] || { echo 'agent must run as a non-root user' >&2; exit 1; }
[[ ! -S /var/run/docker.sock ]] || { echo 'unexpected host Docker socket' >&2; exit 1; }

fixture="$(mktemp -d)"
project="dockersand-test-$$"
compose=(docker compose --project-name "$project" -f "$fixture/compose.yml")
cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "$project" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT

# Concurrent invocations must share a single daemon.
docker info >/dev/null &
first=$!
docker info >/dev/null &
second=$!
wait "$first"
wait "$second"
docker info --format '{{json .SecurityOptions}}' | rg -q 'name=rootless'

cat >"$fixture/Dockerfile" <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache busybox-extras && printf 'built-inside-sandbox\n' >/proof
EOF
docker build -t "$project" "$fixture"
[[ "$(docker run --rm "$project" cat /proof)" == built-inside-sandbox ]]
printf 'bind-mounted\n' >"$fixture/mounted"
[[ "$(docker run --rm -v "$fixture:/fixture:ro" "$project" cat /fixture/mounted)" == bind-mounted ]]
docker run --rm "$project" wget -qO /dev/null https://example.com
echo 'PASS: image build, run, bind mount, DNS and outbound HTTPS'

cat >"$fixture/compose.yml" <<EOF
services:
  server:
    image: $project
    command: [httpd, -f, -p, '8080', -h, /]
    ports: ['127.0.0.1::8080']
    healthcheck:
      test: [CMD, wget, -qO-, 'http://127.0.0.1:8080/proof']
      interval: 1s
      timeout: 3s
      retries: 10
  client:
    image: $project
    profiles: [test]
    command: [wget, -qO-, 'http://server:8080/proof']
EOF
"${compose[@]}" up -d --wait --wait-timeout 30
[[ "$("${compose[@]}" run --rm client)" == built-inside-sandbox ]]
address="$("${compose[@]}" port server 8080)"
[[ "$(curl -fsS "http://$address/proof")" == built-inside-sandbox ]]
echo 'PASS: Compose networking, service DNS and published ports'
