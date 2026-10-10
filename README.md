# dockersand

`dockersand` wraps Docker and gVisor, creating lightweight sandboxes
for your trusted-ish workloads, such as well-meaning LLM agents.
It prevents them from accessing files outside the current project,
devices and (optionally) network resources, while providing enough
integrations around commonly used tooling (SSH, gcloud, Docker-in-Docker), that
working in a Docker container doesn't feel frustrating.

It's like pocket sand - it certainly won't stop anyone, but it'll definitely maybe slow them down.

## Installation

Prerequisites: [gVisor installed and configured as a Docker runtime](https://gvisor.dev/docs/user_guide/quick_start/docker/).
If you would like to use SSH forwarding, configure runsc with `--host-uds=open`, and set `DOCKERSAND_SSH=1` when running.

For now, installation is manual. Drop every `dockersand*` script on your `PATH`.

You will also need to build and tag the images you would like to use. The example `Dockerfile`s in `dockerfiles/` are
`claude`, `codex`, `opencode`, `bash`, and a base image for them all: `agents`. To build the full suite:

```sh
docker build -t agents -f dockerfiles/Dockerfile.agents .
docker build -t bash -f dockerfiles/Dockerfile.bash .
docker build -t claude -f dockerfiles/Dockerfile.claude .
docker build -t codex -f dockerfiles/Dockerfile.codex .
docker build -t opencode -f dockerfiles/Dockerfile.opencode .
```

`dockersand` is not prescriptive - it'll work with any Docker image you supply it.

## Usage

```sh
dockersand <app> [app-args...]
```

launches a Docker container from an image tagged `<app>`, mounting the repository (or directory, if
outside a git repo) you are in at `/home/work/repos/<repo-name>` (where `repo-name` is the name of the top-level repository directory).
If you are in a repository subdirectory, it drops you into the same one in the sandbox as well.

By default (inside a git repository) the sandbox works in a separate clone, so it doesn't see uncommitted changes
and can't modify your `.git`. Use `DOCKERSAND_GIT_STRATEGY=mount` to work in the checkout directly.

The easiest way to explore the environment (without building anything) is running `dockersand alpine`.
If you've built the base images, running `dockersand bash` will get you the same environment the agent images run in.

### Per-repo image

If you launch `dockersand` inside a git repository, it will first check for an image named `<repo-name>-<app>`,
before falling back to `<app>`.
This enables baking custom images per repository, including repository-specific tooling.

### Per-app hooks

`dockersand-args-*` files are per-app hooks. They are used to pass additional arguments to Docker, allowing mounting
application-specific configuration directories (such as `~/.config/opencode`).

The bundled hooks mount these directories read-write, so the sandbox can
plant code that runs on the host the next time you use that app outside the sandbox (e.g. hooks in `~/.claude/settings.json`,
plugins in `~/.config/opencode`, or MCP server commands in `~/.codex/config.toml`). Unlike `.git`, this isn't limited
to one repository. If you also run these apps unsandboxed, review changes to their configuration, or edit the hooks to
mount only what the app needs.

### Git strategy

`DOCKERSAND_GIT_STRATEGY` selects what the sandbox works in: `clone` (the default) or `mount`.

With `clone`, the sandbox works in a separate clone, so it doesn't see uncommitted changes and can't modify your
`.git`. Each run is a new session with its own clone, kept at `~/.local/state/dockersand/repos/<checkout>/<session>/<repo-name>`,
so sandboxes started from the same checkout don't share anything. The clone starts on your current branch, has
your remotes, and is independent of the working copy. Bring the work back from your sandbox:

    git fetch ~/.local/state/dockersand/repos/<checkout>/<session>/<repo-name> <branch>

The session name is random and printed at startup. Set `DOCKERSAND_SESSION_NAME` to resume a session, or to give a
new one a memorable name:

    DOCKERSAND_SESSION_NAME=<session> dockersand <app> [args...]

A session runs in at most one sandbox at a time: its container is named after it, and Docker refuses to start a
second one.

The sandbox's whole `~/repos` is `~/.local/state/dockersand/repos/<checkout>/<session>`, so anything created next to
the clone, such as a `git worktree add ../<branch>`, persists with the session. Branches committed in those worktrees
live in the clone, so the same `git fetch` brings them back.

Never run git anywhere under `~/.local/state/dockersand/repos` on the host: hooks and config there are under the
sandbox's control. Sessions accumulate, each a full clone: delete a session's directory to drop it, or
`<checkout>` to drop all of a checkout's sessions.

This works best with workflows which end in PRs/branches being pushed to the target repository by the agent,
and is suitable for running potentially destructive actions on the sandboxed repository. Note that it only
protects your working copy: the clone keeps your remotes, so with `DOCKERSAND_SSH=1` the sandbox can still push to them.

Use `DOCKERSAND_GIT_STRATEGY=mount` to work directly in the checkout, including its `.git`. That means the sandbox can
plant hooks or config (e.g. `core.fsmonitor`) that your host git later executes. It also doesn't work from
linked git worktrees, whose `.git` points outside the mount. Outside a git repository the default is to mount
the directory (equivalent to `mount`).

### Git identity

The sandbox receives `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL`
from the identity Git resolves in your host checkout. This respects repository-specific config, conditional
includes, and explicit `GIT_AUTHOR_*` / `GIT_COMMITTER_*` environment overrides. Author and committer identities
are resolved separately. The host's gitconfig is not mounted, and commit timestamps are not forwarded.

### Docker inside the sandbox

The `agents` base image includes Docker Engine, Buildx, Compose, and rootless Docker tooling. Opt-in is
required due to security concessions this makes - it uses the `runc` runtime instead of `runsc`, enables
`SYS_ADMIN`, disables the outer seccomp/AppArmor profiles and proc/sys mount restrictions, and permits
setuid UID/GID mapping helpers. It trades gVisor isolation for nested-container support; ordinary launches
retain `runsc` and `no-new-privileges`. The host must support unprivileged user namespaces and provide
`/dev/net/tun`, which is passed through for userspace networking.

```sh
DOCKERSAND_DIND=1 dockersand bash
# Inside the sandbox:
docker run --rm hello-world
docker build -t my-solution .
docker compose up --build
```


The nested daemon starts on the first Docker command and runs as `work`, using a private Unix socket.
It uses the `vfs` storage driver for compatibility with nested filesystems. Images, containers and volumes
last for the sandbox's lifetime; Docker does not use the host daemon or its socket. Publish nested ports
with `docker run -p` to reach them from the agent inside the sandbox. Rootless cgroup resource limits are
unavailable without a user systemd session. Startup logs are at `/home/work/.docker/run/dockerd.log`.

### Entrypoint override

`DOCKERSAND_ENTRYPOINT` overrides the image's default entrypoint. Any `[args...]` are passed to the new entrypoint:

```sh
DOCKERSAND_ENTRYPOINT=/bin/bash dockersand <app> -l
```

This is useful when debugging per-app hooks, environment setup, etc.

### SSH forwarding

Set `DOCKERSAND_SSH=1` to forward the SSH agent into the sandbox. If `SSH_AUTH_SOCK` is present, it is passed in,
alongside a `.ssh/known_hosts` mount. This requires that gVisor is configured with the `--host-uds=open` flag.
The `known_hosts` mount is only added when `DOCKERSAND_SSH=1`, since `known_hosts` lists every host you've SSHed to.

If `DOCKERSAND_SSH` is `1` but `SSH_AUTH_SOCK` is not set, no agent socket is forwarded (no error is raised).

```sh
DOCKERSAND_SSH=1 dockersand <app> [args...]
```

### Egress filtering

`DOCKERSAND_EGRESS=1` enables egress filtering by creating the sandbox in a network with no route to the outside, except
through a Squid HTTP + SSH proxy. A running egress proxy (with an example Docker Compose setup in [`egress-proxy`](./egress-proxy/))
is required:

```sh
cd egress-proxy
docker compose up -d
DOCKERSAND_EGRESS=1 dockersand <app> [args...]
```

The `squid.permissive.conf` file in that directory is the default - it enables access to everything except your private
network and the host.
`squid.conf`, on the other hand, only enables traffic to major inference providers, GitHub, npm and PyPI. It will most
likely require adjustment to fit your specific use-case.

It is also possible to allow access to inference provider running on the host, as `host.docker.internal`, by
uncommenting `http_access allow host_services` rules in configuration, but
keep in mind that your host's firewall will treat this traffic like any other,
so you may need to open up some ports.

### gcloud

The `agents` base image includes the Google Cloud CLI. Set `DOCKERSAND_GCLOUD=1` to authenticate it with an access token
from the host's `gcloud auth print-access-token`, and to pass in the host's default project as `CLOUDSDK_CORE_PROJECT`.
`~/.config/gcloud` is not mounted, so the sandbox never sees your refresh tokens or account name. The launch fails if
the host has no `gcloud` or can't print a token.

```sh
DOCKERSAND_GCLOUD=1 dockersand <app> [args...]
```

While the sandbox runs, a background process on the host asks gcloud for the token every 2 minutes. Usually that returns
gcloud's cached token, which it renews once under ~4 minutes of its hour remain. The process stops and deletes the
token as soon as the sandbox quits, and also stops if a refresh fails, after which gcloud in the sandbox loses access
within the hour. Tokens are kept in `$XDG_RUNTIME_DIR/dockersand` (or `~/.local/state/dockersand`). With
`DOCKERSAND_EGRESS=1`, `squid.conf` also needs to allow `.googleapis.com`.

### Host gateway

Without egress filtering, the host is reachable from the sandbox as `host.docker.internal`, for example to use an
inference provider running on the host. `DOCKERSAND_HOST_GATEWAY` changes the name; set it empty to omit it:

```sh
DOCKERSAND_HOST_GATEWAY=host.internal dockersand <app> [args...]
DOCKERSAND_HOST_GATEWAY= dockersand <app> [args...]
```

Omitting the name doesn't block access to the host: the sandbox can still reach it by the gateway IP. Only egress
filtering does that. With `DOCKERSAND_EGRESS=1`, this variable is ignored, as the sandbox reaches the host through
the proxy (see below).

## Alternatives
There are scores of us, dozens even! If you are looking for agent isolation
in particular, [this gist](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e) has them all.

If you're looking for something even more generic than this, `wc -l dockersand`
may be enlightening on the build-vs-buy conundrum.

## Tests

Run `bash tests/launcher.sh` to check Git identity resolution and runtime selection without a Docker daemon.
After rebuilding the images, test nested builds, networking and Compose with:

```sh
DOCKERSAND_GIT_STRATEGY=mount DOCKERSAND_DIND=1 dockersand bash tests/dind.sh
```
