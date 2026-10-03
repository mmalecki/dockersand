# dockersand

`dockersand` wraps Docker and gVisor, creating lightweight sandboxes
for your trusted-ish workloads, such as well-meaning LLM agents.
It prevents them from accessing files outside the current project,
devices and (optionally) network resources.

It's like pocket sand - it certainly won't stop anyone, but it'll definitely maybe slow them down.

## Installation

Prerequisites: [gVisor installed and configured as a Docker runtime](https://gvisor.dev/docs/user_guide/quick_start/docker/).
If you would like to use SSH forwarding, configure runsc with `--host-uds=open`.

For now, installation is manual. Drop every `dockersand*` script on your `PATH`.

You will also need to build and tag the images you would like to use. The example `Dockerfile`s in `dockerfiles/` are
`claude`, `codex`, `opencode`, `bash`, and a base image for them all: `agents`. To build the full suite:

```sh
docker build -t agents -f dockerfiles/agents .
docker build -t bash -f dockerfiles/bash .
docker build -t claude -f dockerfiles/claude .
docker build -t codex -f dockerfiles/codex .
docker build -t opencode -f dockerfiles/opencode .
```

`dockersand` is not prescriptive - it'll work with any Docker image you supply it.

## Usage

```sh
dockersand <app> [app-args...]
```

launches a Docker container from an image tagged `<app>`,
mounting the repository or directory you are in at `/home/work/repos/<repo-name>`
(where `repo-name` is the name of the top-level repository directory).
If you've been operating in a repository subdirectory, it drops you into the same one in the sandbox as well.

The easiest way to explore the environment (without building anything) is running `dockersand alpine`.
If you've built the base images, running `dockersand bash` will get you the same environment the agent images run in.

### Per-repo image

If you launch `dockersand` inside a git repository, it will first check for an image named `<repo-name>-<app>`,
before falling back to `<app>`.
This enables baking custom images per repository, including repository-specific tooling.

### Per-app hooks

`dockersand-*` files are per-app hooks. They are used to pass additional arguments to Docker, allowing mounting
application-specific configuration directories (such as `~/.config/opencode`).

The bundled hooks mount these directories read-write, so, like `.git` with the `mount` git strategy, the sandbox can
plant code that runs on the host the next time you use that app outside the sandbox: hooks in `~/.claude/settings.json`,
plugins in `~/.config/opencode`, or MCP server commands in `~/.codex/config.toml`. Unlike `.git`, this isn't limited
to one repository. If you also run these apps unsandboxed, review changes to their configuration, or edit the hooks to
mount only what the app needs.

### Git strategy

`DOCKERSAND_GIT_STRATEGY` selects what the sandbox works in: `mount` (the default) or `clone`.

With `mount`, the sandbox works directly in your checkout, including its `.git`. That means the sandbox can
plant hooks or config (e.g. `core.fsmonitor`) that your host git later executes. It also doesn't work from
linked git worktrees, whose `.git` points outside the mount.

`DOCKERSAND_GIT_STRATEGY=clone dockersand <app> [args...]` runs the sandbox in a persistent clone instead, kept under
`~/.local/state/dockersand/clones/` (one per checkout) and reused across runs. The clone starts on your
current branch, has your remotes, and doesn't include uncommitted changes. Bring the work back from your
own checkout:

    git fetch ~/.local/state/dockersand/clones/<name> <branch>

Never run git *inside* the clone on the host: its hooks and config are under the sandbox's control.
Delete the clone to start fresh.

This works best with workflows which end in PRs/branches being pushed to the target repository by the agent,
and is suitable for running potentially destructive actions on the sandboxed repository. Note that it only
protects your working copy: the clone keeps your remotes, so with SSH forwarding the sandbox can still push to them.

### Entrypoint override

`DOCKERSAND_ENTRYPOINT` overrides the image's default entrypoint. Any `[args...]` are passed to the new entrypoint:

```sh
DOCKERSAND_ENTRYPOINT=/bin/bash dockersand <app> -l
```

This is useful when debugging per-app hooks.

### SSH forwarding

If `SSH_AUTH_SOCK` is present, it is passed into the Docker container, alongside a `.ssh/known_hosts` mount.
This requires that gVisor is configured with the `--host-uds=open` flag. This enables the sandbox to reuse the host's
SSH credentials (for example, to `git push`).

To disable SSH forwarding for a single run:

```sh
SSH_AUTH_SOCK= dockersand <app> [args...]
```

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

### Egress filtering

`DOCKERSAND_EGRESS=1` enables egress filtering by creating the sandbox in a network with no route to the outside, except
through a Squid HTTP + SSH proxy. A running egress proxy (with an example Docker Compose setup in [`egress-proxy`](./egress-proxy/))
is required:

```sh
cd egress-proxy
docker compose up -d
DOCKERSAND_EGRESS=1 dockersand <app> [args...]
```

The `squid.conf` file in that directory enables traffic to major inference providers, GitHub, npm and PyPI, but it
should be adjusted to fit your specific use-case.

It is also possible to allow access to inference provider running on the host by
uncommenting `http_access allow host_services` rules in `squid.conf`, but
keep in mind that your host's firewall will treat this traffic like any other,
so you may need to open up some ports.

## Alternatives
There are scores of us, dozens even! If you are looking for agent isolation
in particular, [this gist](https://gist.github.com/wincent/2752d8d97727577050c043e4ff9e386e) has them all.

If you're looking for something even more generic than this, `wc -l dockersand`
may be enlightening on the build-vs-buy conundrum.
