# Discourse image — standalone, OCI-friendly, 12-factor.
# Builds from upstream discourse/discourse at a pinned ref. Pitchfork on :3000.
# See README.md for design notes (especially the plugin model).
#
# Build:
#   docker build \
#     --build-arg DISCOURSE_VERSION=v2026.4.0 \
#     -t ghcr.io/pikapods/docker-discourse:v2026.4.0 .

ARG RUBY_VERSION=3.4
ARG NODE_VERSION=24
# BASE_IMAGE is composed by build.yml as ruby:<minor>-slim-trixie optionally
# suffixed with @sha256:... when the watcher resolved a digest. Local builds
# without a digest fall through to the floating tag.
ARG BASE_IMAGE=ruby:${RUBY_VERSION}-slim-trixie
# Discourse moved to calendar-versioned tags (vYYYY.M.PATCH). The rolling
# "release" tag points at the current stable build; CI overrides this
# with a dated tag at dispatch time.
ARG DISCOURSE_VERSION=release
ARG DISCOURSE_REPO=https://github.com/discourse/discourse
ARG DISCOURSE_UID=1000
ARG DISCOURSE_GID=1000
ARG S6_OVERLAY_VERSION=3.2.0.2

# ── Stage 1: builder ────────────────────────────────────────────────────────
FROM ${BASE_IMAGE} AS builder
ARG DISCOURSE_VERSION
ARG DISCOURSE_REPO
ARG NODE_VERSION
ENV LANG=C.UTF-8 \
    RAILS_ENV=production \
    NODE_ENV=production

RUN apt-get update && apt-get install -y --no-install-recommends \
        git build-essential libpq-dev libssl-dev libxml2-dev libxslt1-dev \
        libyaml-dev libjpeg-dev libfreetype6-dev zlib1g-dev pkg-config bison \
        brotli openssl curl ca-certificates \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g pnpm@10 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone at the requested ref. Shallow clone is fast for tags/branches, but
# `git clone --branch=<sha>` is rejected by GitHub, so a 40-hex ref takes
# the full-clone + checkout path.
RUN if echo "${DISCOURSE_VERSION}" | grep -Eq '^[0-9a-f]{40}$'; then \
        git clone "${DISCOURSE_REPO}" /app && \
        git -C /app checkout "${DISCOURSE_VERSION}"; \
    else \
        git clone --depth=1 --branch="${DISCOURSE_VERSION}" "${DISCOURSE_REPO}" /app; \
    fi

# Pin gem install path BEFORE deployment=true. Bundler's deployment mode
# otherwise defaults to vendor/bundle (project-relative), which breaks our
# runtime COPY --from=builder /usr/local/bundle.
RUN bundle config set --local path /usr/local/bundle \
 && bundle config set --local without 'development test' \
 && bundle config set --local deployment 'true' \
 && bundle install --jobs=4 --retry=3

RUN pnpm install --frozen-lockfile

# Move ALL bundled plugins out of /app/plugins → /opt/discourse-plugins-core,
# then symlink only the default set back in. The core stash lives OUTSIDE
# Rails root on purpose: keeping a second copy of every plugin under /app
# caused Discourse's autoloader to register each constant twice (once via
# the live symlink path, once via the plugins-core sibling), producing
# "already initialized constant" warnings at boot. assets:precompile then
# bakes assets matching the runtime default surface, so a no-config first
# boot doesn't need to rebuild.
RUN mkdir -p /opt/discourse-plugins-core \
 && if [ -n "$(ls -A /app/plugins 2>/dev/null)" ]; then \
        mv /app/plugins/* /opt/discourse-plugins-core/; \
    fi

# Bake the default-active set as a sibling file. Single source of truth for
# "what does 'default' mean" — read here at build time and at runtime by
# the bootstrap script.
RUN printf '%s\n' \
        checklist \
        discourse-details \
        discourse-narrative-bot \
        discourse-presence \
        discourse-reactions \
        styleguide \
      > /app/baked-default-plugins

RUN while read p; do \
        [ -d "/opt/discourse-plugins-core/$p" ] && ln -s "/opt/discourse-plugins-core/$p" "/app/plugins/$p"; \
    done < /app/baked-default-plugins

# Build-time precompile against the default-6. SKIP_DB_AND_REDIS skips
# the live-service probes; SKIP_EMBER_CLI_COMPILE is NOT set because the
# Ember build must actually run here. themes:update is omitted (needs a DB).
#
# We keep /app/.git in the image: assemble_ember_build.rb (invoked by
# assets:precompile during a runtime plugin rebuild) shells out to
# `git rev-parse --git-dir` to compute the core tree hash. Without it,
# the runtime rebuild path aborts. The shallow clone is small enough
# to not be worth saving the disk.
RUN SKIP_DB_AND_REDIS=1 \
    DISCOURSE_SECRET_KEY_BASE=$(openssl rand -hex 64) \
        bundle exec rake assets:precompile \
 && rm -rf /app/.github /app/spec /app/test /app/tmp
# /app/docs is NOT removed: SeedData::Topics#admin_quick_start_raw reads
# /app/docs/ADMIN-QUICK-START-GUIDE.md during db:migrate seeding. Stripping
# it raises Errno::ENOENT, prints a backtrace on every first boot, and
# skips the Admin Quick Start pinned topic.

# Copy the shared hash helper now so we can bake a manifest matching what
# bootstrap will compute at runtime. Identical script → identical hash →
# no spurious rebuild on first boot.
COPY rootfs/usr/local/bin/discourse-manifest-hash /usr/local/bin/discourse-manifest-hash
RUN /usr/local/bin/discourse-manifest-hash \
        --builtin-file /app/baked-default-plugins \
        --third-party-file /dev/null \
      > /app/baked-plugin-manifest

# ── Stage 2: runtime ────────────────────────────────────────────────────────
FROM ${BASE_IMAGE} AS runtime
ARG DISCOURSE_UID
ARG DISCOURSE_GID
ARG NODE_VERSION
ARG RUBY_VERSION
ARG S6_OVERLAY_VERSION
ARG DISCOURSE_VERSION

# Build identity. IMAGE_REVISION is bumped by build.yml when the same
# DISCOURSE_VERSION is rebuilt against a new base digest (security patch).
# BASE_DIGEST is the resolved sha256 the FROM line pinned to; upstream-watch
# reads it back off the published image to detect base-image drift.
ARG IMAGE_REVISION=r1
ARG BASE_DIGEST=
ARG GIT_SHA=
ARG BUILD_DATE=

LABEL org.opencontainers.image.title="Discourse" \
      org.opencontainers.image.description="Standalone, 12-factor Discourse container" \
      org.opencontainers.image.source="https://github.com/pikapods/docker-discourse" \
      org.opencontainers.image.licenses="GPL-2.0" \
      org.opencontainers.image.version="${DISCOURSE_VERSION}-${IMAGE_REVISION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="ruby:${RUBY_VERSION}-slim-trixie" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

# Runtime libs + the same toolchain the builder used. The toolchain is
# retained on purpose: runtime plugin install needs to compile native gems
# and run Ember/Webpack. A "slim" image that fails on every plugin install
# is a worse outcome than a 1.4 GB image that works.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 imagemagick jpegoptim optipng pngquant gifsicle \
        postgresql-client redis-tools tzdata openssl rsync \
        brotli curl ca-certificates gosu xz-utils libjemalloc2 \
        git build-essential libpq-dev libssl-dev libxml2-dev libxslt1-dev \
        libyaml-dev libjpeg-dev libfreetype6-dev zlib1g-dev pkg-config bison \
    && curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g pnpm@10 \
    && rm -rf /var/lib/apt/lists/*

# s6-overlay v3.
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) S6_ARCH=x86_64 ;; \
        arm64) S6_ARCH=aarch64 ;; \
        *) echo "unsupported $ARCH"; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/s6n.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" && \
    curl -fsSL -o /tmp/s6a.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6n.tar.xz && \
    tar -C / -Jxpf /tmp/s6a.tar.xz && \
    rm /tmp/s6*.tar.xz

RUN groupadd -g "${DISCOURSE_GID}" discourse && \
    useradd -u "${DISCOURSE_UID}" -g "${DISCOURSE_GID}" -m -d /home/discourse -s /bin/bash discourse

COPY --from=builder --chown=${DISCOURSE_UID}:${DISCOURSE_GID} /app /app
# Keep the baked bundle at a stable build-time path. Bootstrap rsyncs it
# into /data/cache/bundle (the runtime BUNDLE_PATH) on first boot. The
# baked tree is read-only state; the runtime tree is what gets mutated.
COPY --from=builder --chown=${DISCOURSE_UID}:${DISCOURSE_GID} /usr/local/bundle /usr/local/bundle-baked
# Bundled plugin stash lives outside Rails root to avoid autoloader double-
# scanning (see comment in the builder stage). Bootstrap symlinks the active
# subset from here into /app/plugins on every boot.
COPY --from=builder --chown=${DISCOURSE_UID}:${DISCOURSE_GID} /opt/discourse-plugins-core /opt/discourse-plugins-core

WORKDIR /app

# /data layout + symlink wiring. /app/plugins is empty at this point
# (the builder moved plugins-core out, then symlinks were torn out before
# the COPY; see comment below). The bootstrap rebuilds /app/plugins at boot
# from /opt/discourse-plugins-core + /data/plugins.
#
# /app/public/assets is symlinked to /data/cache/assets; the baked content
# is staged at /app/assets-baked so bootstrap can seed it.
RUN mkdir -p /data/uploads /data/backups /data/plugins /data/cache/bundle /data/cache/assets \
 && mv /app/public/assets /app/assets-baked \
 && rm -rf /app/public/uploads /app/public/backups \
 && rm -rf /app/plugins && mkdir -p /app/plugins \
 && ln -s /data/uploads /app/public/uploads \
 && ln -s /data/backups /app/public/backups \
 && ln -s /data/cache/assets /app/public/assets \
 && chown -R discourse:discourse /data /app/plugins \
 && chown -h discourse:discourse /app/public/uploads /app/public/backups /app/public/assets

# Overlay our rootfs (s6 services, bootstrap, hash helper, seed_admin.rb).
# Scripts in rootfs/ are committed with +x bits so COPY preserves them.
COPY rootfs/ /
# COPY rootfs/ / recreates /app and /app/script as root-owned (because
# rootfs/app/script/ exists). Re-chown them so git's "dubious ownership"
# check at /app passes when the discourse user runs assemble_ember_build.rb.
RUN chown discourse:discourse /app /app/script /app/script/seed_admin.rb

ENV RAILS_ENV=production \
    NODE_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    DISCOURSE_SERVE_STATIC_ASSETS=true \
    LANG=C.UTF-8 \
    CONTAINER_DISCOURSE_DB_MIGRATE=TRUE \
    CONTAINER_DISCOURSE_ENABLE_SIDEKIQ=TRUE \
    BUNDLE_PATH=/data/cache/bundle \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

EXPOSE 3000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD curl -fsS http://localhost:3000/srv/status -o /dev/null || exit 1

ENTRYPOINT ["/init"]
