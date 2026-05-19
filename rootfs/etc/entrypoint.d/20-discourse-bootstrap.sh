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

# Flipped to 1 by seed_or_link_cache whenever it changes on-disk state
# (creation, repair, or replacement of an existing manifest-volume's cache
# state). The manifest-decision step below must not take the "unchanged"
# branch when this is 1 — see the repair-loses-context failure mode.
caches_repaired=0

# Validators: cache-specific "is this dir a complete materialized cache?"
bundle_dir_valid() { [ -d "$1/ruby" ]; }
assets_dir_valid() {
    # Modern Discourse writes /app/public/assets/.manifest.json (Propshaft)
    # alongside manifest-<digest>.json (Sprockets). Presence of either =
    # complete. Glob-only check via `set --`; a non-matching dotfile glob
    # under default `set +f` stays literal, which $1 -e then rejects.
    if [ -f "$1/.manifest.json" ]; then return 0; fi
    set -- "$1"/manifest-*.json
    [ -e "$1" ]
}

# Seed /data/cache subdir as a symlink to its baked source, unless it is
# already a valid materialized real dir. Cleans up any leftover .new/ from
# a prior interrupted materialization first.
#
# Distinguishes "fresh creation on a virgin volume" from "repair of a
# wrong/missing state". Both leave the same end state (a baked symlink),
# but the hash decision needs to treat them differently: fresh creation
# is paired with the manifest-file seed further down, so the unchanged
# branch fires legitimately. Repair invalidates whatever recorded hash
# is already on disk, so the unchanged branch must be suppressed.
# Presence of $MANIFEST_FILE at this point is the discriminator —
# the manifest is seeded from baked only AFTER all seed_or_link_cache calls.
seed_or_link_cache() {
    target=$1; baked=$2; validator=$3
    rm -rf "${target}.new"

    if [ -L "$target" ]; then
        resolved=$(readlink "$target")
        if [ "$resolved" = "$baked" ]; then return 0; fi
        log "WARN: $target -> $resolved; expected -> $baked; replacing"
        rm "$target"
    elif [ -d "$target" ]; then
        if "$validator" "$target"; then return 0; fi
        log "WARN: $target exists but failed $validator; replacing with link to $baked"
        rm -rf "$target"
    elif [ -e "$target" ]; then
        log "WARN: $target is neither directory nor symlink; replacing"
        rm -rf "$target"
    fi

    ln -s "$baked" "$target"
    chown -h "$DISCOURSE_UID:$DISCOURSE_GID" "$target"
    # Repair only — virgin volumes (no MANIFEST_FILE yet) take the
    # unchanged branch via the manifest seed below.
    if [ -f "$MANIFEST_FILE" ]; then
        caches_repaired=1
    fi
}

# Promote a symlinked /data/cache subdir to a writable real directory.
# Refuses to materialize from any source other than the expected baked
# path. Atomic swap via .new staging dir. Idempotent: no-op if already
# a real dir.
materialize_cache() {
    target=$1; baked=$2
    if [ -d "$target" ] && [ ! -L "$target" ]; then return 0; fi
    if [ ! -L "$target" ]; then
        die "$target is missing; cannot materialize"
    fi
    resolved=$(readlink "$target")
    if [ "$resolved" != "$baked" ]; then
        die "$target -> $resolved; refusing to materialize from anything other than $baked"
    fi

    tmp="${target}.new"
    rm -rf "$tmp"
    log "materializing $target from $baked"
    mkdir "$tmp"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$tmp"
    rsync -a "$baked/" "$tmp/"

    rm "$target"
    mv "$tmp" "$target"
}

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
         DISCOURSE_DEVELOPER_EMAILS DISCOURSE_SECRET_KEY_BASE
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
#    a fresh named volume doesn't need any host-side prep. /data/cache/bundle
#    and /data/cache/assets themselves are managed by seed_or_link_cache
#    below (lazy symlink unless a previous boot materialized them).
# ---------------------------------------------------------------------------
for d in "$DATA_DIR/uploads" "$DATA_DIR/backups" "$DATA_DIR/plugins" \
         "$DATA_DIR/cache"
do
    mkdir -p "$d"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$d"
done

# ---------------------------------------------------------------------------
# 4. Seed runtime caches as symlinks pointing at the baked snapshots.
#    BUNDLE_PATH points at /data/cache/bundle; without a working target,
#    Rails has no gems and the boot fails before we can do anything useful.
#    Bundler (deployment=true, frozen=true) and Pitchfork read through the
#    symlinks; nothing writes. Materialization (real rsynced dir) is
#    deferred to the rebuild branch, which is the only path that needs
#    write access to the bundle / asset trees.
# ---------------------------------------------------------------------------
seed_or_link_cache "$DATA_DIR/cache/bundle" "$BAKED_BUNDLE" bundle_dir_valid
seed_or_link_cache "$DATA_DIR/cache/assets" "$BAKED_ASSETS" assets_dir_valid

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
# 8. Compute manifest hash. Drives the split rebuild that straddles
#    migrations: gems before, themes+assets after.
# ---------------------------------------------------------------------------
current_hash=$(/usr/local/bin/discourse-manifest-hash \
    --builtin-file "$BUILTIN_LIST" \
    --third-party-file "$ACTIVE_TP_FILE" \
    --image-fingerprint-file /app/baked-image-fingerprint)
baked_hash=$(cat "$BAKED_MANIFEST")
recorded_hash=
[ -f "$MANIFEST_FILE" ] && recorded_hash=$(cat "$MANIFEST_FILE")

# Three-branch decision:
#   1. unchanged AND no cache repair  → nothing to do
#   2. matches baked default AND both → fast adopt: caches automatically
#      caches are valid baked            follow the new image; just bump
#      symlinks                          the recorded hash
#   3. else                            → full rebuild (gems + migrate +
#                                         themes/assets)
#
# Branch 1 must respect caches_repaired: if seed_or_link_cache had to
# replace a wrong/invalid/missing cache state, the on-disk gems/assets
# no longer match what recorded_hash claims, so "unchanged" would
# wrongly skip a rebuild that's now necessary to repopulate.
# Branch 2 already passes a stronger check (both are symlinks to baked
# AND current_hash matches the baked default), so it does not need to
# gate on caches_repaired.
rebuild=no
if [ "$current_hash" = "$recorded_hash" ] && [ "$caches_repaired" = "0" ]; then
    log "plugin manifest unchanged (hash $current_hash); skipping rebuild"
elif [ "$current_hash" = "$baked_hash" ] \
        && [ -L "$DATA_DIR/cache/bundle" ] \
        && [ -L "$DATA_DIR/cache/assets" ]; then
    log "plugin set matches baked default and caches are symlinked; adopting hash $current_hash"
    printf '%s\n' "$current_hash" > "$MANIFEST_FILE"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$MANIFEST_FILE"
else
    rebuild=yes
    if [ "$caches_repaired" = "1" ] && [ "$current_hash" = "$recorded_hash" ]; then
        log "caches were repaired; forcing rebuild despite unchanged manifest hash $current_hash"
    else
        log "plugin manifest changed ($recorded_hash -> $current_hash); rebuilding"
    fi
fi

# ---------------------------------------------------------------------------
# 9. Rebuild phase 1 (pre-migrate): materialize caches and install gems.
#    Runs before db:migrate so a plugin that needs a new gem during Rails
#    boot or in a migration has it available. Themes+assets are deferred
#    to phase 2 because themes:update needs the DB.
#
#    deployment/frozen are unset just for `bundle install` (mirroring the
#    upstream web.template.yml flow) and re-pinned IMMEDIATELY after, so
#    db:migrate runs with the same pinned Bundler config it sees today.
# ---------------------------------------------------------------------------
if [ "$rebuild" = "yes" ]; then
    materialize_cache "$DATA_DIR/cache/bundle" "$BAKED_BUNDLE"
    materialize_cache "$DATA_DIR/cache/assets" "$BAKED_ASSETS"
    ( cd "$APP_DIR" && as_app bash -c '
        set -e
        bundle config unset --local deployment >/dev/null
        bundle config unset --local frozen >/dev/null
        bundle install --jobs=4 --retry=3
    ' ) >&2 || die "bundle install failed"
    # Re-pin deployment NOW so migrations run with the same pinned
    # Bundler config they see in today's pre-split flow.
    as_app bundle config set --local deployment 'true' >/dev/null
fi

# ---------------------------------------------------------------------------
# 10. Migrations. Gems from phase 1 are present; Bundler is back in
#     deployment mode.
# ---------------------------------------------------------------------------
if [ "${CONTAINER_DISCOURSE_DB_MIGRATE:-TRUE}" = "TRUE" ]; then
    log "running db:migrate"
    ( cd "$APP_DIR" && as_app bundle exec rake db:migrate ) >&2 \
        || die "db:migrate failed"
fi

# ---------------------------------------------------------------------------
# 11. Rebuild phase 2 (post-migrate): themes (DB-dependent) + asset
#     precompile. Both run with deployment pinned — neither task modifies
#     the bundle, so the looser config used in today's combined block was
#     incidental rather than required. Manifest hash is recorded only
#     after both phases succeed; an interruption here leaves recorded_hash
#     stale and the next boot retries the whole rebuild.
# ---------------------------------------------------------------------------
if [ "$rebuild" = "yes" ]; then
    ( cd "$APP_DIR" && as_app bundle exec rake themes:update assets:precompile ) >&2 \
        || die "themes:update + assets:precompile failed"
    printf '%s\n' "$current_hash" > "$MANIFEST_FILE"
    chown "$DISCOURSE_UID:$DISCOURSE_GID" "$MANIFEST_FILE"
    log "rebuild complete; manifest hash recorded"
fi

# ---------------------------------------------------------------------------
# 12. Admin seed — idempotent. Skipped silently when no email set.
# ---------------------------------------------------------------------------
if [ -n "${CONTAINER_DISCOURSE_ADMIN_EMAIL:-}" ]; then
    log "seeding admin user (idempotent)"
    ( cd "$APP_DIR" && as_app bundle exec rails runner /app/script/seed_admin.rb ) >&2 \
        || die "admin seed failed (CONTAINER_DISCOURSE_ADMIN_EMAIL was set)"
fi

log "bootstrap complete"
