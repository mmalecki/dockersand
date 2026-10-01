# dockersand

`dockersand` wraps Docker and gVisor, creating lightweight sandboxes
for your trusted-ish workloads, such as well-meaning LLM agents.
It prevents them from accessing files outside the current project,
devices and (optionally) network resources.

It's like pocket sand - it certainly won't stop anyone, but it'll definitely maybe slow them down.

## Installation

For now, manual. Drop every `dockersand*` script on your `PATH`.

## Usage

`dockersand <app> [args...]` launches a Docker container from an image tagged `<app>`,
mounting the repository or directory you are in, inside its `/home/work/repos` directory.

The easiest way to explore the environment this gets you is running `dockersand alpine`.

### Per-repo image

If you launch `dockersand` inside a git repository, it will first check for an image named `<repo-name>-<app>`
(where `repo-name` is the name of the top-level repository directory), before falling back to `<app>`.
This enables baking custom images per repository, including repository-specific tooling.

### Per-app hooks

`dockersand-*` files are per-app hooks. They are used to pass additional arguments to Docker, allowing mounting
application-specific configuration directories (such as `~/.config/opencode`).
