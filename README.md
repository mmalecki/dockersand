# dockersand

`dockersand` wraps Docker and gVisor, creating lightweight sandboxes
for your trusted-ish workloads, such as well-meaning LLM agents.
It prevents them from accessing files outside the current project,
devices and (optionally) network resources.

It's like pocket sand - it certainly won't stop anyone, but it'll definitely maybe slow them down.

## Installation

Prerequisites: [gVisor installed and configured as Docker runtime](https://gvisor.dev/docs/user_guide/quick_start/docker/).
If you would like to use SSH forwarding, configure it with `--host-uds=open`.

For now, installation process is manual. Drop every `dockersand*` script on your `PATH`.

You will also need to build and tag the images you would like to use. Some example `Dockerfile`s include
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
If you've built the base images, running `dockersand bash` will get you an environment that's the target agent runtime environment.

### Per-repo image

If you launch `dockersand` inside a git repository, it will first check for an image named `<repo-name>-<app>`,
before falling back to `<app>`.
This enables baking custom images per repository, including repository-specific tooling.

### Per-app hooks

`dockersand-*` files are per-app hooks. They are used to pass additional arguments to Docker, allowing mounting
application-specific configuration directories (such as `~/.config/opencode`).

### Separate clone

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
and is suitable for running potentially destructive actions on the sandboxed repository.

### SSH forwarding

If `SSH_AUTH_SOCK` is present, it is passed into the Docker container, alongside a `.ssh/known_hosts` mount.
This requires that gVisor is configured with `--host-uds=open` switch. This enables the sandbox to reuse host's
SSH credentials (for example, to `git push`).

### Egress filtering

`DOCKERSAND_EGRESS` enables egress filtering by creating the sandbox in a network with no route to the outside, except
through a Squid HTTP + SSH proxy. A running egress proxy (with example Docker Compose set up in [`egress-proxy`](./egress-proxy/))
is required:

```sh
cd egress-proxy
docker compose up -d
```

The `squid.conf` file in that directory enables traffic to major inference providers, but it should be adjusted to fit
your specific use-case.
