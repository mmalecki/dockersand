#!/usr/bin/env bash
set -euo pipefail

# Client-only commands don't need a daemon (including during image builds).
case "${1:-}" in
  --version | -v | --help | -h | help)
    exec /usr/bin/docker "$@"
    ;;
esac

if [[ "${DOCKERSAND_DIND:-}" != 1 ]]; then
  echo "rootless Docker is disabled; launch with DOCKERSAND_DIND=1 dockersand <app>" >&2
  exit 1
fi

# Start on first use, so derived images can keep their agent entrypoints.
if ! /usr/bin/docker info >/dev/null 2>&1; then
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"
  # Serialize concurrent first calls from agents and their subprocesses.
  exec 9>"$XDG_RUNTIME_DIR/docker-start.lock"
  flock 9
  if ! /usr/bin/docker info >/dev/null 2>&1; then
    log="$XDG_RUNTIME_DIR/dockerd.log"
    # vfs avoids overlay-on-overlay and /dev/fuse requirements when nested.
    dockerd-rootless.sh \
      --host="$DOCKER_HOST" \
      --storage-driver=vfs \
      --feature=containerd-snapshotter=false \
      >"$log" 2>&1 </dev/null 9>&- &
    daemon_pid=$!
    ready=0
    for ((attempt = 0; attempt < 30; attempt++)); do
      if /usr/bin/docker info >/dev/null 2>&1; then
        ready=1
        break
      fi
      if ! kill -0 "$daemon_pid" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    if [[ "$ready" != 1 ]]; then
      echo "rootless Docker failed to start; see $log" >&2
      cat "$log" >&2
      exit 1
    fi
  fi
  flock -u 9
  exec 9>&-
fi

exec /usr/bin/docker "$@"
