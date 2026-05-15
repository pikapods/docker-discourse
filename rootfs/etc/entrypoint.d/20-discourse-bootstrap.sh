#!/command/with-contenv sh
# Discourse bootstrap — runs as the s6 oneshot before web/sidekiq start.
#
# Order matters: this script is the single place that turns a fresh /data
# volume + a bag of env vars into a ready-to-run Rails app. Everything is
# idempotent; state is derived from the DB and /data/cache/.plugin-manifest, not
# from sentinel files.
set -eu

APP_DIR=/app
DATA_DIR=/data
BAKED_BUNDLE=/usr/local/bundle-baked
BAKED_ASSETS=/app/assets-baked
BAKED_MANIFEST=/app/baked-plugin-manifest
BAKED_DEFAULT_PLUGINS=/app/baked-default-plugins
PLUGINS_CORE_DIR=/opt/discourse-plugins-core
PLUGINS_LIVE_DIR=/app/plugins
THIRD_PARTY_DIR=/data/plugins
MANIFEST_FILE=/data/cache/.plugin-manifest

DISCOURSE_UID=$(id -u discourse)
DISCOURSE_GID=$(id -g discourse)

log() { printf '[discourse-bootstrap] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

as_app() { gosu discourse:discourse "$@"; }

# ---------------------------------------------------------------------------
# 1. Preflight — /data writability. Same diagnostic style as freescout: an
#    unchowned bind mount is the #1 first-run failure and a bare "permission
#    denied" buried in a later step is not actionable.
# ---------------------------------------------------------------------------
if ! ( : > "$DATA_DIR/.write-test" ) 2>/dev/null; then
    cat >&2 <<EOF
ERROR: $DATA_DIR is not writable by the container.
       Expected ownership: ${DISCOURSE_UID}:${DISCOURSE_GID} (the 'discourse' user).
       Fix one of:
         - chown the host bind-mount target to ${DISCOURSE_UID}:${DISCOURSE_GID}
         - rootless podman: --userns=keep-id:uid=${DISCOURSE_UID},gid=${DISCOURSE_GID}
         - use a named docker volume instead of a bind mount
         - rebuild with --build-arg DISCOURSE_UID=... DISCOURSE_GID=...
EOF
    exit 1
fi
rm -f "$DATA_DIR/.write-test"

# ---------------------------------------------------------------------------
# 2. Validate required env. DISCOURSE_SECRET_KEY_BASE is mandatory and has
#    no fallback or auto-generation — rotating it silently would invalidate
#    sessions and corrupt encrypted columns. Better to fail loud once.
# ---------------------------------------------------------------------------
missing=
for v in DISCOURSE_HOSTNAME DISCOURSE_DB_HOST DISCOURSE_DB_USERNAME \
         DISCOURSE_DB_PASSWORD DISCOURSE_DB_NAME DISCOURSE_REDIS_HOST \
         DISCOURSE_SMTP_ADDRESS DISCOURSE_DEVELOPER_EMAILS \
         DISCOURSE_SECRET_KEY_BASE
do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
    log "ERROR: required env vars unset:$missing"
    case "$missing" in
        *DISCOURSE_SECRET_KEY_BASE*)
            log "       DISCOURSE_SECRET_KEY_BASE has no default. Generate one once and"
            log "       keep it stable across container recreates:"
            log "           openssl rand -hex 64"
            log "       Rotating it invalidates all sessions and breaks encrypted DB columns."
            ;;
    esac
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Ensure /data subtree exists. Discourse-side dirs are created here so
#    a fresh named volume doesn't need any host-side prep.
# ---------------------------------------------------------------------------
for d in "$DATA_DIR/uploads" "$DATA_DIR/backups" "$DATA_DIR/plugins" \
         "$DATA_DIR/cache/bundle" "$DATA_DIR/cache/assets"
do
    mkdir -p "$d"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$d"
done

# ---------------------------------------------------------------------------
# 4. Seed runtime caches from the baked snapshots on first boot.
#    BUNDLE_PATH points at /data/cache/bundle; without seeding, Rails has
#    no gems and the boot fails before we can do anything useful.
# ---------------------------------------------------------------------------
# Detect a populated bundle by the presence of a `ruby/<abi>/gems` subdir
# rather than `[ -z "$(ls)" ]` — a stray dotfile shouldn't fool us.
if [ ! -d "$DATA_DIR/cache/bundle/ruby" ]; then
    log "seeding bundle cache from $BAKED_BUNDLE"
    # rsync -a preserves the source's discourse:discourse ownership when
    # run as root, so no follow-up chown is needed.
    rsync -a "$BAKED_BUNDLE/" "$DATA_DIR/cache/bundle/"
fi

# Public/assets is a symlink to /data/cache/assets. Empty target = 404s on
# every static request; seed from /app/assets-baked which holds the build-
# time precompile output.
if [ -z "$(ls -A "$DATA_DIR/cache/assets" 2>/dev/null)" ]; then
    log "seeding asset cache from $BAKED_ASSETS"
    rsync -a "$BAKED_ASSETS/" "$DATA_DIR/cache/assets/"
fi

# Pre-seed the manifest hash with the baked (default-6) value. When the
# operator's env matches the default surface, step 9's hash check will
# match this seeded value and the expensive rebuild is skipped.
if [ ! -f "$MANIFEST_FILE" ] && [ -f "$BAKED_MANIFEST" ]; then
    log "seeding $MANIFEST_FILE from baked manifest"
    cp "$BAKED_MANIFEST" "$MANIFEST_FILE"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$MANIFEST_FILE"
fi

# Configure bundler for the discourse user. deployment/frozen stay set so
# the seeded bundle is treated as locked; if the manifest rebuild step
# later adds a plugin gem, it unsets them just for that invocation.
as_app bundle config set --local path "$DATA_DIR/cache/bundle" >/dev/null
as_app bundle config set --local without 'development test' >/dev/null
as_app bundle config set --local deployment 'true' >/dev/null

# ---------------------------------------------------------------------------
# 5. Postgres readiness.
# ---------------------------------------------------------------------------
DB_PORT=${DISCOURSE_DB_PORT:-5432}
log "waiting for postgres at ${DISCOURSE_DB_HOST}:${DB_PORT} (60s)"
deadline=$(( $(date +%s) + 60 ))
until pg_isready -h "$DISCOURSE_DB_HOST" -p "$DB_PORT" -U "$DISCOURSE_DB_USERNAME" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "postgres at ${DISCOURSE_DB_HOST}:${DB_PORT} not reachable within 60s"
    sleep 1
done
log "postgres reachable"

# ---------------------------------------------------------------------------
# 6. Redis readiness. Honour password + TLS the same way Discourse does.
# ---------------------------------------------------------------------------
REDIS_PORT=${DISCOURSE_REDIS_PORT:-6379}
redis_args="-h $DISCOURSE_REDIS_HOST -p $REDIS_PORT"
[ -n "${DISCOURSE_REDIS_PASSWORD:-}" ] && redis_args="$redis_args -a $DISCOURSE_REDIS_PASSWORD"
case "${DISCOURSE_REDIS_USE_SSL:-}" in
    1|true|TRUE|yes|YES) redis_args="$redis_args --tls" ;;
esac
log "waiting for redis at ${DISCOURSE_REDIS_HOST}:${REDIS_PORT} (30s)"
deadline=$(( $(date +%s) + 30 ))
# redis-cli ping returns "PONG" on success — grep is the cheap way to
# distinguish a connection error from "PONG".
# shellcheck disable=SC2086
until redis-cli $redis_args ping 2>/dev/null | grep -q PONG; do
    [ "$(date +%s)" -lt "$deadline" ] || die "redis at ${DISCOURSE_REDIS_HOST}:${REDIS_PORT} not reachable within 30s"
    sleep 1
done
log "redis reachable"

# ---------------------------------------------------------------------------
# 7. Plugin sync.
#    Two env vars drive this:
#      CONTAINER_DISCOURSE_PLUGINS_BUILTIN  — allow-list of bundled plugins.
#      CONTAINER_DISCOURSE_PLUGINS          — third-party manifest.
# ---------------------------------------------------------------------------
# Normalise a single name: lowercase, swap underscores for dashes, then
# match against $PLUGINS_CORE_DIR. Accept both "discourse-foo" and "foo"
# spellings — the bundled set is conventionally prefixed but operators
# routinely drop the prefix.
normalise_builtin() {
    raw=$1
    candidate=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    if [ -d "$PLUGINS_CORE_DIR/$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if [ -d "$PLUGINS_CORE_DIR/discourse-$candidate" ]; then
        printf '%s\n' "discourse-$candidate"
        return 0
    fi
    return 1
}

# Resolve the built-in allow-list into a tmp file (one canonical name per line).
BUILTIN_LIST=$(mktemp)
# ACTIVE_TP_FILE holds "<name>\t<HEAD-sha>" lines for the third-party plugins
# we're actually symlinking into /app/plugins this boot — fed to the manifest
# hasher so the dropped-but-cached plugin set doesn't poison the hash.
ACTIVE_TP_FILE=$(mktemp)
trap 'rm -f "$BUILTIN_LIST" "${THIRD_PARTY_LIST:-}" "$ACTIVE_TP_FILE"' EXIT

# Empty vs unset matters: empty = "no plugins, please"; unset = "give me the
# baked defaults". `${VAR+set}` is the natural POSIX probe, but it doesn't
# work here — `with-contenv` is `s6-envdir` underneath, which silently drops
# variables whose file in /run/s6/container_environment is 0 bytes. So
# `docker run -e VAR=` arrives at this script as unset, not empty. Probe the
# envdir directly to recover the explicit-empty case.
S6_ENV_DIR=/run/s6/container_environment
if [ -e "$S6_ENV_DIR/CONTAINER_DISCOURSE_PLUGINS_BUILTIN" ]; then
    builtin_raw=$(cat "$S6_ENV_DIR/CONTAINER_DISCOURSE_PLUGINS_BUILTIN")
    builtin_set=yes
else
    builtin_raw=
    builtin_set=no
fi
if [ "$builtin_set" = "no" ]; then
    log "CONTAINER_DISCOURSE_PLUGINS_BUILTIN unset; using baked default-6"
    cp "$BAKED_DEFAULT_PLUGINS" "$BUILTIN_LIST"
elif [ -z "$builtin_raw" ]; then
    log "CONTAINER_DISCOURSE_PLUGINS_BUILTIN empty; disabling all bundled plugins"
    : > "$BUILTIN_LIST"
elif [ "$builtin_raw" = "*" ]; then
    log "CONTAINER_DISCOURSE_PLUGINS_BUILTIN=*; enabling every bundled plugin"
    ( cd "$PLUGINS_CORE_DIR" && ls -1 ) > "$BUILTIN_LIST"
else
    CONTAINER_DISCOURSE_PLUGINS_BUILTIN=$builtin_raw
    # Split on commas + whitespace, dropping blanks. Empty entries (",,")
    # are tolerated so block-scalar yaml works.
    printf '%s\n' "$CONTAINER_DISCOURSE_PLUGINS_BUILTIN" \
        | tr ',' '\n' \
        | while IFS= read -r raw; do
              # POSIX-portable trim.
              trimmed=$(printf '%s' "$raw" | awk '{$1=$1; print}')
              [ -n "$trimmed" ] || continue
              if name=$(normalise_builtin "$trimmed"); then
                  printf '%s\n' "$name"
              else
                  log "WARN: unknown bundled plugin '$trimmed' (not under $PLUGINS_CORE_DIR); ignoring"
              fi
          done > "$BUILTIN_LIST"
fi

# Parse the third-party manifest into "<url>\t<ref>\t<name>" lines.
THIRD_PARTY_LIST=$(mktemp)
: > "$THIRD_PARTY_LIST"
if [ -n "${CONTAINER_DISCOURSE_PLUGINS:-}" ]; then
    printf '%s\n' "$CONTAINER_DISCOURSE_PLUGINS" \
        | tr ',' '\n' \
        | while IFS= read -r raw; do
              entry=$(printf '%s' "$raw" | awk '{$1=$1; print}')
              [ -n "$entry" ] || continue
              # Pull off the optional #name then optional @ref. Order matters:
              # split off name (after final '#') first so a '#' in the ref is
              # not a thing anyone actually does.
              name=
              case "$entry" in
                  *'#'*) name=${entry##*#}; entry=${entry%#*} ;;
              esac
              ref=main
              case "$entry" in
                  *'@'*) ref=${entry##*@}; url=${entry%@*} ;;
                  *)     url=$entry ;;
              esac
              if [ -z "$name" ]; then
                  name=$(basename "$url")
                  name=${name%.git}
              fi
              printf '%s\t%s\t%s\n' "$url" "$ref" "$name"
          done > "$THIRD_PARTY_LIST"
fi

# Clone / update third-party plugins. Network failures on already-cached
# plugins are demoted to a WARN so offline boots succeed when the cache is
# at the right ref. $THIRD_PARTY_DIR was created and chowned in step 3.
while IFS=$(printf '\t') read -r url ref name; do
    [ -n "$name" ] || continue
    dest="$THIRD_PARTY_DIR/$name"
    # SHA = 40 lowercase hex chars.
    if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
        ref_kind=sha
    else
        ref_kind=mutable
    fi

    if [ ! -d "$dest/.git" ]; then
        rm -rf "$dest"
        log "cloning $name from $url@$ref"
        if [ "$ref_kind" = "sha" ]; then
            # Some servers reject --branch=<sha>; fall back to a full clone.
            if ! as_app git clone --depth=1 --branch="$ref" "$url" "$dest" 2>/dev/null; then
                as_app git clone "$url" "$dest" || die "clone failed: $name"
                as_app git -C "$dest" checkout "$ref" || die "checkout $ref failed: $name"
            fi
        else
            as_app git clone --depth=1 --branch="$ref" "$url" "$dest" \
                || die "clone failed: $name@$ref"
        fi
    else
        cur=$(as_app git -C "$dest" rev-parse HEAD 2>/dev/null || echo "")
        if [ "$ref_kind" = "sha" ] && [ "$cur" = "$ref" ]; then
            log "plugin $name: already at $ref"
        else
            log "fetching $name origin $ref"
            if as_app timeout 15 git -C "$dest" fetch origin "$ref" 2>/dev/null; then
                as_app git -C "$dest" checkout FETCH_HEAD --detach >/dev/null 2>&1 || \
                    as_app git -C "$dest" reset --hard FETCH_HEAD
            else
                log "WARN: plugin $name: fetch of $ref failed, using cached HEAD ${cur:-unknown}"
            fi
        fi
    fi
done < "$THIRD_PARTY_LIST"

# Atomic swap of /app/plugins. New tree built fully under .new/, then mv.
NEW_DIR="${PLUGINS_LIVE_DIR}.new"
rm -rf "$NEW_DIR"
mkdir -p "$NEW_DIR"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$PLUGINS_CORE_DIR/$name"
    [ -d "$src" ] || { log "WARN: missing bundled plugin source: $src"; continue; }
    ln -s "$src" "$NEW_DIR/$name"
done < "$BUILTIN_LIST"
: > "$ACTIVE_TP_FILE"
while IFS=$(printf '\t') read -r _ _ name; do
    [ -n "$name" ] || continue
    src="$THIRD_PARTY_DIR/$name"
    [ -d "$src" ] || { log "WARN: missing third-party plugin source: $src"; continue; }
    ln -s "$src" "$NEW_DIR/$name"
    # Capture the HEAD sha of every plugin we actually link in, so the
    # manifest hash reflects only the live set (not stale cache leftovers).
    if sha=$(as_app git -c safe.directory='*' -C "$src" rev-parse HEAD 2>/dev/null); then
        printf '%s\t%s\n' "$name" "$sha" >> "$ACTIVE_TP_FILE"
    fi
done < "$THIRD_PARTY_LIST"
rm -rf "$PLUGINS_LIVE_DIR"
mv "$NEW_DIR" "$PLUGINS_LIVE_DIR"

# ---------------------------------------------------------------------------
# 8. Migrations.
# ---------------------------------------------------------------------------
if [ "${CONTAINER_DISCOURSE_DB_MIGRATE:-TRUE}" = "TRUE" ]; then
    log "running db:migrate"
    ( cd "$APP_DIR" && as_app bundle exec rake db:migrate ) >&2 \
        || die "db:migrate failed"
fi

# ---------------------------------------------------------------------------
# 9. Conditional rebuild — only when the plugin manifest hash differs from
#    the recorded one. Hash is written only after both bundle install and
#    asset precompile succeed, so a half-built state does not poison the
#    next boot.
# ---------------------------------------------------------------------------
current_hash=$(/usr/local/bin/discourse-manifest-hash \
    --builtin-file "$BUILTIN_LIST" \
    --third-party-file "$ACTIVE_TP_FILE")
recorded_hash=
[ -f "$MANIFEST_FILE" ] && recorded_hash=$(cat "$MANIFEST_FILE")

if [ "$current_hash" = "$recorded_hash" ]; then
    log "plugin manifest unchanged (hash $current_hash); skipping rebuild"
else
    log "plugin manifest changed ($recorded_hash -> $current_hash); rebuilding"
    # Plugin gems may need to be installed: drop deployment/frozen for
    # this one invocation, matching upstream's web.template.yml flow.
    ( cd "$APP_DIR" && as_app bash -c '
        set -e
        bundle config unset --local deployment >/dev/null
        bundle config unset --local frozen >/dev/null
        bundle install --jobs=4 --retry=3
        bundle exec rake themes:update assets:precompile
    ' ) >&2 || die "plugin rebuild failed (bundle install + themes:update + assets:precompile)"
    # Re-pin deployment now that the new gems are present.
    as_app bundle config set --local deployment 'true' >/dev/null
    printf '%s\n' "$current_hash" > "$MANIFEST_FILE"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$MANIFEST_FILE"
    log "rebuild complete; manifest hash recorded"
fi

# ---------------------------------------------------------------------------
# 10. Admin seed — idempotent. Skipped silently when no email set.
# ---------------------------------------------------------------------------
if [ -n "${CONTAINER_DISCOURSE_ADMIN_EMAIL:-}" ]; then
    log "seeding admin user (idempotent)"
    ( cd "$APP_DIR" && as_app bundle exec rails runner /app/script/seed_admin.rb ) >&2 \
        || die "admin seed failed (CONTAINER_DISCOURSE_ADMIN_EMAIL was set)"
fi

log "bootstrap complete"
