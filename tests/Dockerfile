# The image tests/live.sh launches. Build from the repository root.
# Rootless Docker is set up as in dockerfiles/Dockerfile.agents, for tests/dind.sh,
# and the D-Bus clients are there for tests/dbus-integration.sh.
FROM debian:trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    busybox ca-certificates curl git openssh-client \
    dbus-bin libnotify-bin libsecret-tools \
    uidmap slirp4netns iproute2 \
 && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc \
 && chmod go+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
    > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras \
    docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# The host user's UID, so that what the sandbox writes is theirs. 0 under
# rootless Docker, which maps the host user to root.
ARG WORK_UID=1000
# useradd allocates subordinate IDs for rootless containers by default.
RUN if [ "$WORK_UID" != 0 ]; then \
      useradd --uid "$WORK_UID" -m work \
      && test -s /etc/subuid && test -s /etc/subgid \
      && install -d -m 700 -o work -g work /home/work/.docker /home/work/.docker/run; \
    fi
USER $WORK_UID

COPY --chmod=755 dockerfiles/docker-rootless.sh /usr/local/bin/docker
ENV XDG_RUNTIME_DIR=/home/work/.docker/run
ENV DOCKER_HOST=unix:///home/work/.docker/run/docker.sock
