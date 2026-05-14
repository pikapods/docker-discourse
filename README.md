# docker-discourse

A standalone, OCI-friendly Docker image for [Discourse](https://github.com/discourse/discourse).

Unlike upstream's `discourse_docker` (a bash launcher that owns the
container lifecycle), this image is a plain container: external Postgres,
Redis, SMTP, and reverse proxy. It uses Discourse's own `DISCOURSE_*` env
vars unchanged, runs **Pitchfork** on port 3000, and precompiles core
assets at build time for fast cold boot.

## Quick start

```sh
# 1. Seed your local .env from the example, then put a secret_key_base in it.
#    .env is gitignored; .env.example shows the variables compose.yaml reads.
cp .env.example .env
sed -i "s|^DISCOURSE_SECRET_KEY_BASE=.*|DISCOURSE_SECRET_KEY_BASE=$(openssl rand -hex 64)|" .env

# 2. Edit compose.yaml to fill in DISCOURSE_HOSTNAME, SMTP, admin email.

# 3. Up.
docker compose up -d
```

Browse to `http://localhost:3000`. First-boot admin credentials come from
`CONTAINER_DISCOURSE_ADMIN_EMAIL` / `_PASSWORD`.

## Image layout

| Path | Purpose |
|---|---|
| `/app` | Discourse source tree (read-only at runtime) |
| `/opt/discourse-plugins-core/` | Bundled plugins as shipped by upstream (kept outside Rails root to avoid autoloader double-scanning) |
| `/app/plugins/` | Active plugin set (symlinks; rebuilt at boot) |
| `/app/assets-baked/` | Precompiled asset snapshot from build time |
| `/usr/local/bundle-baked/` | Gem bundle snapshot from build time |
| `/data/` | Operator-owned volume (see below) |

### `/data` (mount point)

```
/data/
├── uploads/          ← user uploads (symlinked from /app/public/uploads)
├── backups/          ← discourse backups (symlinked from /app/public/backups)
├── plugins/          ← cloned third-party plugin sources
└── cache/
    ├── bundle/         ← BUNDLE_PATH; seeded from baked on first boot
    ├── assets/         ← symlinked from /app/public/assets
    └── .plugin-manifest ← sha256 of resolved plugin set
```

A single volume mounted at `/data` is enough — the subdirs are internal
organisation. Logs go to stdout.

## Environment variables

### Required

| Var | Notes |
|---|---|
| `DISCOURSE_HOSTNAME` | Public hostname (no scheme) |
| `DISCOURSE_DB_HOST` | Postgres host |
| `DISCOURSE_DB_USERNAME` | |
| `DISCOURSE_DB_PASSWORD` | |
| `DISCOURSE_DB_NAME` | |
| `DISCOURSE_REDIS_HOST` | |
| `DISCOURSE_SMTP_ADDRESS` | |
| `DISCOURSE_DEVELOPER_EMAILS` | Comma-separated; these accounts become admins on signup |
| `DISCOURSE_SECRET_KEY_BASE` | **Env-only, no fallback.** Generate once with `openssl rand -hex 64` and keep it stable. Rotating it invalidates sessions and breaks encrypted columns. |

### Common optional `DISCOURSE_*` (passthrough)

`DISCOURSE_DB_PORT`, `DISCOURSE_DB_POOL`,
`DISCOURSE_REDIS_PORT`, `DISCOURSE_REDIS_PASSWORD`, `DISCOURSE_REDIS_USE_SSL`,
`DISCOURSE_SMTP_PORT`, `DISCOURSE_SMTP_USER_NAME` (note the underscore — canonical upstream spelling),
`DISCOURSE_SMTP_PASSWORD`, `DISCOURSE_SMTP_DOMAIN`, `DISCOURSE_SMTP_AUTHENTICATION`,
`DISCOURSE_SMTP_ENABLE_START_TLS`, `DISCOURSE_SMTP_FORCE_TLS`,
`DISCOURSE_SMTP_OPENSSL_VERIFY_MODE`,
`DISCOURSE_CDN_URL`, `DISCOURSE_S3_*`,
`DISCOURSE_ENABLE_CORS`, `DISCOURSE_CORS_ORIGIN`.

All `DISCOURSE_*` vars are read directly by Discourse's `config/discourse.conf`;
they pass through unchanged.

### Image-owned `CONTAINER_DISCOURSE_*`

| Var | Default | Purpose |
|---|---|---|
| `CONTAINER_DISCOURSE_PLUGINS_BUILTIN` | _unset_ → default-6 (`checklist`, `discourse-details`, `discourse-narrative-bot`, `discourse-presence`, `discourse-reactions`, `styleguide`) | Allow-list for bundled plugins. `""` = none, `*` = all, `"checklist,poll"` = exact set. See [discourse/discourse/plugins](https://github.com/discourse/discourse/tree/main/plugins) for the full list of bundled plugins. |
| `CONTAINER_DISCOURSE_PLUGINS` | _empty_ | Third-party plugin manifest: `<url>[@<ref>][#<name>]`, comma-separated |
| `CONTAINER_DISCOURSE_DB_MIGRATE` | `TRUE` | Run `rake db:migrate` at bootstrap |
| `CONTAINER_DISCOURSE_ENABLE_SIDEKIQ` | `TRUE` | Start the sidekiq longrun |
| `CONTAINER_DISCOURSE_ADMIN_EMAIL` | _unset_ | First-boot admin seed (skipped if any admin exists) |
| `CONTAINER_DISCOURSE_ADMIN_PASSWORD` | _unset_ | Required when ADMIN_EMAIL is set and no admin exists |
| `CONTAINER_DISCOURSE_ADMIN_USERNAME` | `admin` | |
| `CONTAINER_DISCOURSE_PITCHFORK_WORKERS` | `3` | Pitchfork worker count |
| `CONTAINER_DISCOURSE_SIDEKIQ_CONCURRENCY` | `5` | Sidekiq thread count |

## Plugins

Plugins are full Rails sub-projects: adding one means re-running
`bundle install` (it may declare gems), `assets:precompile`, and a
migration. This image accepts the cost honestly: the first boot after a
plugin change runs all three, and the manifest hash is stored in
`/data/cache/.plugin-manifest` so subsequent boots skip the rebuild.

### Bundled vs third-party

Discourse ships ~43 plugins under [`plugins/` in the source tree](https://github.com/discourse/discourse/tree/main/plugins)
("bundled") — `chat`, `discourse-ai`, `discourse-narrative-bot`, ... These
are all baked into the image at `/opt/discourse-plugins-core/`. Use
`CONTAINER_DISCOURSE_PLUGINS_BUILTIN` to choose which ones are active:

- _unset_ → the default-6 (`checklist`, `discourse-details`,
  `discourse-narrative-bot`, `discourse-presence`,
  `discourse-reactions`, `styleguide`). This is the no-config boot path
  and it does **not** trigger a rebuild — the build-time precompile
  produced assets for exactly this set.
- `""` (empty) → all bundled plugins disabled. Triggers one rebuild.
- `"checklist,poll"` → only those two. Short aliases work too
  (`narrative-bot` resolves to `discourse-narrative-bot`).
- `"*"` → every plugin in `/opt/discourse-plugins-core/`. Heavy first rebuild;
  subsequent boots fast.

Third-party plugins are listed in `CONTAINER_DISCOURSE_PLUGINS`:

```yaml
environment:
  CONTAINER_DISCOURSE_PLUGINS: >-
    https://github.com/discourse/discourse-prometheus@main,
    https://github.com/discourse/discourse-akismet@v1.0.0,
    https://github.com/discourse/discourse-canned-replies@abc1234
```

Each entry: `<git_url>[@<ref>][#<name>]`. The ref can be a branch, tag, or
40-char SHA. SHAs are immutable; mutable refs trigger a rebuild whenever
the remote HEAD advances (the manifest hash incorporates `git rev-parse
HEAD`, so a forward-moving `main` doesn't go unnoticed).

### Offline behaviour

When the cache at `/data/plugins/` is already at the right ref, a network
failure during `git fetch` is non-fatal — a warning is logged and the
cached HEAD is used. This means a healthy boot once is enough to make
subsequent offline boots succeed.

A plugin in the manifest that has **never** been cached and can't be
cloned causes the bootstrap to fail loudly.

## User & permissions

The container runs as `discourse` (UID/GID 1000:1000). On a bind mount,
chown the host target to 1000:1000 first; on rootless podman use
`--userns=keep-id:uid=1000,gid=1000`. Named volumes need no host-side
prep.

Rebuild with a custom UID/GID if the defaults clash:

```sh
docker build \
  --build-arg DISCOURSE_UID=$(id -u) \
  --build-arg DISCOURSE_GID=$(id -g) \
  -t docker-discourse:local .
```

## Healthcheck

`GET /srv/status` — Discourse's own readiness endpoint. Initial
start-period is 180s to absorb the first migration on a fresh DB.
