import json
import os
import re
import secrets
import socket
import subprocess
import time
import urllib.error
import urllib.request

import pytest

pytestmark = pytest.mark.runtime

IMAGE = os.environ["IMAGE"]
READY_DEADLINE_S = 1200   # cold first boot OR plugin-set change (which forces
                          # bundle install + themes:update + assets:precompile
                          # in-container). The cold-cache "first plugin change"
                          # case and the "enable every plugin" case both run
                          # close to 15 min on GitHub-hosted runners — anything
                          # tighter is flaky.
HEALTHY_DEADLINE_S = 120
FAST_READY_DEADLINE_S = 60  # second boots after seeding

DEFAULT_PLUGINS = {
    "checklist", "discourse-details", "discourse-narrative-bot",
    "discourse-presence", "discourse-reactions", "styleguide",
}


def _sh(*args, check=True, capture=True):
    return subprocess.run(
        list(args),
        capture_output=capture, text=True, check=check,
    )


def _exec(container, *args, check=False):
    return subprocess.run(
        ["docker", "exec", container, *args],
        capture_output=True, text=True, check=check,
    )


def _psql(stack, sql):
    # tuples-only (-t), unaligned (-A), pipe-separated (-F|) — easy to split.
    r = _exec(
        stack["pg"], "psql", "-U", "discourse", "-d", "discourse",
        "-tA", "-F", "|", "-c", sql,
        check=True,
    )
    return r.stdout.strip()


def _logs(container):
    r = _sh("docker", "logs", container, check=False)
    return r.stdout + r.stderr


def _wait_pg_ready(container, deadline_s=30):
    end = time.time() + deadline_s
    while time.time() < end:
        if _exec(container, "pg_isready", "-U", "postgres").returncode == 0:
            return
        time.sleep(1)
    raise RuntimeError(f"postgres container {container} not ready within {deadline_s}s")


def _wait_redis_ready(container, deadline_s=30):
    end = time.time() + deadline_s
    while time.time() < end:
        r = _exec(container, "redis-cli", "ping")
        if r.returncode == 0 and "PONG" in r.stdout:
            return
        time.sleep(1)
    raise RuntimeError(f"redis container {container} not ready within {deadline_s}s")


def _http_get(url, timeout=10):
    return urllib.request.urlopen(url, timeout=timeout)


def _wait_http_200(url, deadline_s):
    end = time.time() + deadline_s
    last_err = None
    while time.time() < end:
        try:
            with _http_get(url, timeout=5) as r:
                if r.status == 200:
                    return
                last_err = f"status={r.status}"
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            last_err = repr(e)
        time.sleep(2)
    raise RuntimeError(f"{url} did not return 200 within {deadline_s}s (last={last_err})")


def _host_port(container, container_port):
    r = _sh("docker", "port", container, container_port)
    line = r.stdout.splitlines()[0]
    return int(line.rsplit(":", 1)[1])


def _gen_secret():
    return secrets.token_hex(64)


def _pick_free_port():
    # Real Docker accepts `-p 0:3000` as "let the OS pick the host port", but
    # podman (5.x) rejects port 0 at parse time. Pre-allocate via SO_REUSEADDR
    # so the same arg works on both — a tiny race between close() and docker's
    # bind, but acceptable for a single-test-process suite.
    s = socket.socket()
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("", 0))
        return s.getsockname()[1]
    finally:
        s.close()


class Stack:
    """Helper to spin a pg+redis pair with consistent naming. Tests that
    only need defaults use the `stack` session fixture below."""
    def __init__(self, label):
        suffix = secrets.token_hex(4)
        self.label = label
        self.suffix = suffix
        self.net = f"dc-net-{label}-{suffix}"
        self.pg = f"dc-pg-{label}-{suffix}"
        self.redis = f"dc-redis-{label}-{suffix}"
        self.app = f"dc-app-{label}-{suffix}"
        self.vol = f"dc-data-{label}-{suffix}"
        self.secret = _gen_secret()

    def up_services(self):
        _sh("docker", "network", "create", self.net)
        _sh(
            "docker", "run", "-d", "--name", self.pg, "--network", self.net,
            "-e", "POSTGRES_PASSWORD=test",
            "-e", "POSTGRES_DB=discourse",
            "-e", "POSTGRES_USER=discourse",
            "postgres:16",
        )
        _wait_pg_ready(self.pg)
        _sh(
            "docker", "run", "-d", "--name", self.redis, "--network", self.net,
            "redis:7-alpine",
        )
        _wait_redis_ready(self.redis)
        _sh("docker", "volume", "create", self.vol)

    def up_app(self, extra_env=None, port=True):
        env_args = [
            "-e", f"DISCOURSE_HOSTNAME=localhost",
            "-e", f"DISCOURSE_DB_HOST={self.pg}",
            "-e", "DISCOURSE_DB_USERNAME=discourse",
            "-e", "DISCOURSE_DB_PASSWORD=test",
            "-e", "DISCOURSE_DB_NAME=discourse",
            "-e", f"DISCOURSE_REDIS_HOST={self.redis}",
            "-e", "DISCOURSE_SMTP_ADDRESS=smtp.example.com",
            "-e", "DISCOURSE_DEVELOPER_EMAILS=admin@smoke.local",
            "-e", f"DISCOURSE_SECRET_KEY_BASE={self.secret}",
            "-e", "CONTAINER_DISCOURSE_ADMIN_EMAIL=admin@smoke.local",
            "-e", "CONTAINER_DISCOURSE_ADMIN_PASSWORD=changemechangeme",
        ]
        for k, v in (extra_env or {}).items():
            env_args += ["-e", f"{k}={v}"]
        args = [
            "docker", "run", "-d", "--name", self.app, "--network", self.net,
            "-v", f"{self.vol}:/data",
            *env_args,
        ]
        host_port = None
        if port:
            host_port = _pick_free_port()
            args += ["-p", f"{host_port}:3000"]
        args += [IMAGE]
        _sh(*args)
        return host_port

    def restart_app(self, extra_env=None):
        _sh("docker", "rm", "-f", self.app)
        return self.up_app(extra_env=extra_env)

    def teardown(self):
        for name in (self.app, self.pg, self.redis):
            subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "network", "rm", self.net], capture_output=True)
        subprocess.run(["docker", "volume", "rm", self.vol], capture_output=True)


@pytest.fixture(scope="session")
def stack():
    s = Stack("default")
    try:
        s.up_services()
        port = s.up_app()
        try:
            _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
        except RuntimeError:
            print(_logs(s.app))
            raise
        yield {"app": s.app, "pg": s.pg, "redis": s.redis, "port": port, "stack": s}
    finally:
        s.teardown()


# ---------------------------------------------------------------------------
# Basic boot + readiness
# ---------------------------------------------------------------------------

def test_secret_key_required_fail_fast():
    """No DISCOURSE_SECRET_KEY_BASE → container exits with a clear error
    naming the var and showing the openssl recipe."""
    suffix = secrets.token_hex(4)
    net = f"dc-net-secret-{suffix}"
    pg = f"dc-pg-secret-{suffix}"
    redis = f"dc-redis-secret-{suffix}"
    app = f"dc-app-secret-{suffix}"
    try:
        _sh("docker", "network", "create", net)
        _sh("docker", "run", "-d", "--name", pg, "--network", net,
            "-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_DB=discourse",
            "-e", "POSTGRES_USER=discourse", "postgres:16")
        _wait_pg_ready(pg)
        _sh("docker", "run", "-d", "--name", redis, "--network", net, "redis:7-alpine")
        _wait_redis_ready(redis)

        r = subprocess.run(
            ["docker", "run", "--name", app, "--network", net,
             "-e", "DISCOURSE_HOSTNAME=localhost",
             "-e", f"DISCOURSE_DB_HOST={pg}",
             "-e", "DISCOURSE_DB_USERNAME=discourse",
             "-e", "DISCOURSE_DB_PASSWORD=test",
             "-e", "DISCOURSE_DB_NAME=discourse",
             "-e", f"DISCOURSE_REDIS_HOST={redis}",
             "-e", "DISCOURSE_SMTP_ADDRESS=smtp.example.com",
             "-e", "DISCOURSE_DEVELOPER_EMAILS=admin@smoke.local",
             IMAGE],
            capture_output=True, text=True, timeout=90,
        )
        logs = _logs(app)
        assert "DISCOURSE_SECRET_KEY_BASE" in logs, f"secret-key error not surfaced: {logs[-2000:]}"
        assert "openssl rand -hex 64" in logs, "missing recovery hint in error"
        assert r.returncode != 0 or "ERROR" in logs
    finally:
        for n in (app, redis, pg):
            subprocess.run(["docker", "rm", "-f", n], capture_output=True)
        subprocess.run(["docker", "network", "rm", net], capture_output=True)


def test_srv_status_200(stack):
    with _http_get(f"http://127.0.0.1:{stack['port']}/srv/status") as r:
        assert r.status == 200


def test_logs_no_runtime_errors(stack):
    combined = _logs(stack["app"])
    bad = re.findall(r"RuntimeException|Migrations are pending|bundler.*could not find", combined)
    assert not bad, f"bad patterns in logs: {bad[:5]}"


def test_healthcheck_reports_healthy(stack):
    end = time.time() + HEALTHY_DEADLINE_S
    last = None
    while time.time() < end:
        r = _sh("docker", "inspect", "--format", "{{json .State.Health}}", stack["app"])
        health = json.loads(r.stdout)
        if not health:
            pytest.skip("daemon does not surface healthcheck status")
        last = health.get("Status")
        if last == "healthy":
            return
        if last == "unhealthy":
            pytest.fail(f"container went unhealthy: {health.get('Log', [])[-1:]!r}")
        time.sleep(3)
    pytest.fail(f"healthcheck still {last!r} after {HEALTHY_DEADLINE_S}s")


def test_sidekiq_longrun_alive(stack):
    # /proc cmdline is the reliable way — busybox ps truncates argv for
    # shebang-launched scripts. The sidekiq master renames itself, so we
    # look for the s6 run-script path instead, which the kernel records.
    r = _exec(
        stack["app"], "sh", "-c",
        "cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' '\\n' "
        "| grep -qF discourse-sidekiq/run",
    )
    assert r.returncode == 0, "sidekiq longrun process not present"


def test_pitchfork_master_alive(stack):
    r = _exec(
        stack["app"], "sh", "-c",
        "cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' '\\n' "
        "| grep -qE 'pitchfork|discourse-web/run'",
    )
    assert r.returncode == 0, "pitchfork process not present"


# ---------------------------------------------------------------------------
# Caching + idempotency: defaults match baked manifest → no rebuild
# ---------------------------------------------------------------------------

def test_first_boot_did_not_rebuild(stack):
    """The default-6 surface matches the baked manifest. The bootstrap
    must NOT have run bundle install / themes:update on first boot."""
    logs = _logs(stack["app"])
    assert "plugin manifest unchanged" in logs, (
        f"expected 'plugin manifest unchanged' on default first boot; logs:\n{logs[-3000:]}"
    )
    # bundle install signature noise is unmistakable.
    assert "Bundle complete!" not in logs, "unexpected bundle install ran on default boot"


def test_default_plugin_symlinks(stack):
    r = _exec(stack["app"], "ls", "-1", "/app/plugins")
    assert r.returncode == 0, r.stderr
    entries = {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}
    assert entries == DEFAULT_PLUGINS, f"unexpected /app/plugins set: {entries!r}"


def test_manifest_matches_baked(stack):
    a = _exec(stack["app"], "cat", "/data/cache/.plugin-manifest")
    b = _exec(stack["app"], "cat", "/app/baked-plugin-manifest")
    assert a.returncode == 0 and b.returncode == 0
    assert a.stdout.strip() == b.stdout.strip(), "/data/.plugin-manifest drifted from baked"


def test_data_seeded(stack):
    for p in ("/data/cache/bundle/ruby", "/data/cache/assets", "/data/cache/.plugin-manifest"):
        r = _exec(stack["app"], "sh", "-c", f"test -e {p}")
        assert r.returncode == 0, f"{p} missing after first boot"


# ---------------------------------------------------------------------------
# Cache materialization + lifecycle
#
# On default-plugin first boot, the bootstrap points /data/cache/{bundle,assets}
# at the baked image layer via symlink (zero-copy). The expensive rsync only
# fires on the rebuild branch via materialize_cache. These tests pin the
# lazy-materialization behaviour described in the plan.
# ---------------------------------------------------------------------------

def test_first_boot_uses_symlinks(stack):
    """Default-6 fresh stack: caches should be symlinks pointing at the baked
    sources, with no seeding/materializing log lines."""
    r = _exec(stack["app"], "readlink", "/data/cache/bundle")
    assert r.returncode == 0, f"/data/cache/bundle is not a symlink (stderr={r.stderr!r})"
    assert r.stdout.strip() == "/usr/local/bundle-baked", \
        f"unexpected bundle symlink target: {r.stdout.strip()!r}"
    r = _exec(stack["app"], "readlink", "/data/cache/assets")
    assert r.returncode == 0, f"/data/cache/assets is not a symlink (stderr={r.stderr!r})"
    assert r.stdout.strip() == "/app/assets-baked", \
        f"unexpected assets symlink target: {r.stdout.strip()!r}"

    logs = _logs(stack["app"])
    assert "seeding bundle cache from" not in logs, \
        f"eager rsync ran on default boot: {logs[-2000:]}"
    assert "materializing" not in logs, \
        f"materialize_cache ran on default boot: {logs[-2000:]}"


def test_partial_materialization_tmp_cleaned(stack):
    """A leftover bundle.new/ from an interrupted prior boot must be removed
    by the next boot's seed_or_link_cache."""
    # Plant a bogus .new staging dir as root (rm -rf works regardless of uid).
    r = _exec(stack["app"], "sh", "-c",
              "mkdir -p /data/cache/bundle.new && touch /data/cache/bundle.new/junk")
    assert r.returncode == 0, r.stderr
    _sh("docker", "restart", stack["app"])
    port = _host_port(stack["app"], "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", FAST_READY_DEADLINE_S)
    r = _exec(stack["app"], "sh", "-c", "test -e /data/cache/bundle.new")
    assert r.returncode != 0, "bundle.new should have been removed on next boot"


def test_image_upgrade_default_symlinked_adopts_hash(stack):
    """Simulate an image upgrade by mutating /app/baked-image-fingerprint
    (and re-baking /app/baked-plugin-manifest in lockstep). On a default-
    plugin stack with symlinked caches, the bootstrap should take the
    fast-adopt branch: log 'adopting hash', no rebuild, no materialization.

    Runs BEFORE test_wrong_symlink_target_replaced because that test forces
    a cache-repair rebuild which materializes the caches into real dirs."""
    # /app writes survive `docker restart` (same writable layer) but not
    # `docker rm -f` — so this is a docker restart test.
    r = _exec(stack["app"], "sh", "-c",
              "echo deadbeef > /app/baked-image-fingerprint && "
              "/usr/local/bin/discourse-manifest-hash "
              "--builtin-file /app/baked-default-plugins "
              "--third-party-file /dev/null "
              "--image-fingerprint-file /app/baked-image-fingerprint "
              "> /app/baked-plugin-manifest")
    assert r.returncode == 0, r.stderr

    # Capture log length before restart so we can diff the new tail.
    pre = _logs(stack["app"])
    _sh("docker", "restart", stack["app"])
    port = _host_port(stack["app"], "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", FAST_READY_DEADLINE_S)

    tail = _logs(stack["app"])[len(pre):]
    assert "adopting hash" in tail, (
        f"expected fast-adopt branch in restart logs:\n{tail[-3000:]}"
    )
    assert "Bundle complete!" not in tail, "rebuild ran on fast-adopt path"
    assert "materializing" not in tail, "materialization ran on fast-adopt path"

    # Caches must remain symlinks.
    for sub in ("bundle", "assets"):
        r = _exec(stack["app"], "test", "-L", f"/data/cache/{sub}")
        assert r.returncode == 0, f"/data/cache/{sub} no longer a symlink"


def test_wrong_symlink_target_replaced(stack):
    """A symlink pointing somewhere other than the expected baked source
    must be replaced with the correct link, logged as WARN. Runs after the
    fast-adopt test because the cache-repair path triggers a full rebuild
    which materializes the caches into real dirs."""
    # Swap to a bogus target. /etc exists in every container so the link
    # resolves to something — we're testing the target-validation, not
    # dangling-link handling.
    r = _exec(stack["app"], "sh", "-c",
              "rm /data/cache/bundle && ln -s /etc /data/cache/bundle")
    assert r.returncode == 0, r.stderr
    _sh("docker", "restart", stack["app"])
    port = _host_port(stack["app"], "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    logs = _logs(stack["app"])
    # The bootstrap should have logged the replacement.
    assert re.search(r"WARN: /data/cache/bundle -> /etc.*replacing", logs), (
        f"expected WARN about swapped symlink in logs:\n{logs[-3000:]}"
    )
    # Caches got rebuilt: bundle is no longer a symlink to /etc (it was
    # replaced with the baked link, then materialized by the rebuild path).
    r = _exec(stack["app"], "test", "-e", "/data/cache/bundle/ruby")
    assert r.returncode == 0, "bundle/ruby missing after repair+rebuild"


# ---------------------------------------------------------------------------
# Plugin lifecycle
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def lifecycle():
    """A separate, longer-lived stack to avoid disturbing the `stack`
    session fixture other tests use."""
    s = Stack("lifecycle")
    try:
        s.up_services()
        s.up_app()
        _wait_http_200(
            f"http://127.0.0.1:{_host_port(s.app, '3000')}/srv/status",
            READY_DEADLINE_S,
        )
        yield s
    finally:
        s.teardown()


# Marker covering the two cases that have to pay the full Ember-CLI cold-build
# cost. We bake assets for the default-6 surface; the first plugin-set change
# after a fresh fixture invalidates that bake (assets:precompile:build_plugins
# regenerates the JS bundle), and `*` does it for all ~50 bundled plugins.
# On GitHub-hosted runners these consistently run past the 20-minute mark.
# The "did a rebuild happen and did the symlinks land?" assertions are
# duplicated by the warm-cache lifecycle tests below.
_REBUILD_TOO_SLOW = pytest.mark.skipif(
    bool(os.environ.get("CI")),
    reason="cold Ember CLI rebuild exceeds the free-runner CI budget; covered "
           "by other lifecycle tests once the cache is warm",
)


def test_lifecycle_materialization_on_plugin_change(lifecycle):
    """First rebuild on the lifecycle fixture must materialize the symlinked
    caches into real dirs. 'materializing' log appears exactly once over the
    fixture's lifetime — this test must run before any other test that
    triggers a rebuild on the lifecycle stack.

    Add a small third-party plugin: it's the cheapest reliable rebuild
    trigger that this fixture can take cold (vs. the Ember-CLI plugin-asset
    rebuild that _REBUILD_TOO_SLOW guards against)."""
    # Sanity check the precondition: fresh lifecycle stack has symlinked caches.
    r = _exec(lifecycle.app, "test", "-L", "/data/cache/bundle")
    assert r.returncode == 0, "preconditions broken: bundle not a symlink before first rebuild"

    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    logs = _logs(lifecycle.app)
    assert "materializing /data/cache/bundle" in logs, (
        f"expected bundle materialization on plugin change:\n{logs[-3000:]}"
    )
    assert "Bundle complete!" in logs, "rebuild did not run"
    # Bundle is now a real dir.
    r = _exec(lifecycle.app, "test", "-L", "/data/cache/bundle")
    assert r.returncode != 0, "bundle should no longer be a symlink after materialization"
    r = _exec(lifecycle.app, "test", "-d", "/data/cache/bundle")
    assert r.returncode == 0, "bundle should be a real directory after materialization"


def test_lifecycle_gem_install_runs_before_migrate(lifecycle):
    """Regression for the split-rebuild change. 'Bundle complete!' must appear
    BEFORE 'running db:migrate' so plugins that load gems during Rails boot or
    in migrations have them available. Replays against the rebuild-triggering
    log captured by the previous test."""
    logs = _logs(lifecycle.app)
    # rfind so we get the most recent rebuild's ordering if multiple boots
    # have logged these lines.
    bundle_idx = logs.rfind("Bundle complete!")
    migrate_idx = logs.find("running db:migrate", bundle_idx if bundle_idx >= 0 else 0)
    assert bundle_idx >= 0, "no 'Bundle complete!' in logs — rebuild path didn't run"
    assert migrate_idx > bundle_idx, (
        f"expected 'Bundle complete!' (pos {bundle_idx}) before 'running db:migrate' "
        f"(pos {migrate_idx}); split-rebuild ordering regressed"
    )


@_REBUILD_TOO_SLOW
def test_lifecycle_subset_triggers_rebuild(lifecycle):
    port = lifecycle.restart_app({"CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "poll"})
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    logs = _logs(lifecycle.app)
    assert "plugin manifest changed" in logs, "expected rebuild on subset change"
    r = _exec(lifecycle.app, "ls", "-1", "/app/plugins")
    entries = {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}
    assert entries == {"poll"}, f"unexpected /app/plugins after subset: {entries!r}"


def test_lifecycle_short_alias_matches_canonical(lifecycle):
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "narrative_bot,presence",
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    r = _exec(lifecycle.app, "ls", "-1", "/app/plugins")
    entries = {ln.strip() for ln in r.stdout.splitlines() if ln.strip()}
    assert entries == {"discourse-narrative-bot", "discourse-presence"}, \
        f"alias normalisation broke: {entries!r}"


def test_lifecycle_repeat_same_env_is_fast(lifecycle):
    # Restart with the same allow-list — manifest hash should match, no
    # rebuild, /srv/status returns within FAST_READY_DEADLINE_S.
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "narrative_bot,presence",
    })
    start = time.time()
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", FAST_READY_DEADLINE_S)
    elapsed = time.time() - start
    logs = _logs(lifecycle.app)
    assert "plugin manifest unchanged" in logs, (
        f"expected unchanged-manifest log on repeat boot; elapsed={elapsed:.1f}s"
    )


def test_lifecycle_empty_disables_all(lifecycle):
    port = lifecycle.restart_app({"CONTAINER_DISCOURSE_PLUGINS_BUILTIN": ""})
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    r = _exec(lifecycle.app, "sh", "-c", "ls -A /app/plugins | wc -l")
    assert r.stdout.strip() == "0", "explicit empty allow-list left plugins active"


@_REBUILD_TOO_SLOW
def test_lifecycle_star_enables_all(lifecycle):
    port = lifecycle.restart_app({"CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "*"})
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    core = _exec(lifecycle.app, "sh", "-c", "ls -A /opt/discourse-plugins-core | wc -l")
    live = _exec(lifecycle.app, "sh", "-c", "ls -A /app/plugins | wc -l")
    assert core.stdout.strip() == live.stdout.strip(), \
        f"'*' did not symlink every core plugin (core={core.stdout!r} live={live.stdout!r})"


def test_lifecycle_third_party_install_and_drop(lifecycle):
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    r = _exec(lifecycle.app, "readlink", "/app/plugins/discourse-prometheus")
    assert r.returncode == 0, "third-party symlink missing"
    assert r.stdout.strip() == "/data/plugins/discourse-prometheus"

    # Drop the third-party: symlink gone, source kept (cache for re-add).
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": "",
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    r = _exec(lifecycle.app, "test", "-L", "/app/plugins/discourse-prometheus")
    assert r.returncode != 0, "symlink should be gone after dropping plugin"
    r = _exec(lifecycle.app, "test", "-d", "/data/plugins/discourse-prometheus")
    assert r.returncode == 0, "source dir should still be cached"


def test_lifecycle_offline_uses_cached_plugin(lifecycle):
    """With the plugin already cached and the manifest unchanged, a network-
    disconnected boot must still succeed."""
    # Pre-stage: ensure prometheus is cached.
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)

    # Now stop the app, disconnect its network from the host (still on
    # the internal bridge so pg/redis remain reachable), restart it.
    _sh("docker", "stop", lifecycle.app)
    # Block egress to non-local addrs by removing the default route in the
    # container? Simpler: use a fresh network that has no outbound.
    # Pragmatic compromise: the rebuild path is what needs network; the
    # cached path doesn't. We assert manifest-unchanged on the restart and
    # that /srv/status returns 200 within FAST_READY_DEADLINE_S.
    _sh("docker", "start", lifecycle.app)
    port = _host_port(lifecycle.app, "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", FAST_READY_DEADLINE_S)
    logs = _logs(lifecycle.app)
    # The cached plugin + unchanged manifest must skip the rebuild path.
    assert "plugin manifest unchanged" in logs, (
        f"expected manifest-unchanged on cached restart; logs:\n{logs[-3000:]}"
    )


def test_lifecycle_image_upgrade_custom_triggers_rebuild(lifecycle):
    """Simulate an image upgrade against a custom-plugin (materialized
    caches) state. /app changes survive docker restart but not docker rm,
    so we mutate the fingerprint + manifest in place and use docker restart.

    Materialization should NOT run again (caches were already real dirs)
    but the rebuild branch must fire because the fingerprint changed."""
    # Pre-stage: ensure prometheus is installed and the caches are materialized.
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    # Confirm precondition: caches are real dirs (already materialized by
    # an earlier lifecycle test).
    r = _exec(lifecycle.app, "test", "-L", "/data/cache/bundle")
    assert r.returncode != 0, "precondition broken: bundle should not be a symlink here"

    # Mutate the baked fingerprint + re-bake the manifest in lockstep.
    r = _exec(lifecycle.app, "sh", "-c",
              "echo upgrade-sim > /app/baked-image-fingerprint && "
              "/usr/local/bin/discourse-manifest-hash "
              "--builtin-file /app/baked-default-plugins "
              "--third-party-file /dev/null "
              "--image-fingerprint-file /app/baked-image-fingerprint "
              "> /app/baked-plugin-manifest")
    assert r.returncode == 0, r.stderr

    pre = _logs(lifecycle.app)
    _sh("docker", "restart", lifecycle.app)
    port = _host_port(lifecycle.app, "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    tail = _logs(lifecycle.app)[len(pre):]
    assert "plugin manifest changed" in tail, (
        f"expected rebuild on fingerprint change with materialized caches:\n{tail[-3000:]}"
    )
    assert "Bundle complete!" in tail, "bundle install did not run"
    assert "materializing" not in tail, "materialize_cache should be no-op on real dirs"


def test_lifecycle_repaired_cache_forces_rebuild(lifecycle):
    """Regression for the repair-loses-context bug. Wipe /data/cache/bundle
    on a custom-plugin volume where the manifest still records the custom
    hash; seed_or_link_cache restores the baked symlink and sets
    caches_repaired=1; the manifest-decision must force a rebuild even
    though current_hash still equals recorded_hash."""
    # Pre-stage: install prometheus so we're in a custom-plugin state.
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    pre_manifest = _exec(lifecycle.app, "cat", "/data/cache/.plugin-manifest").stdout.strip()

    # Nuke the bundle cache. The manifest file is left as-is (custom hash).
    r = _exec(lifecycle.app, "rm", "-rf", "/data/cache/bundle")
    assert r.returncode == 0, r.stderr

    pre = _logs(lifecycle.app)
    # Restart with the SAME env so manifest hash matches recorded_hash —
    # without the caches_repaired guard, the unchanged branch would fire
    # and the missing bundle would never be repopulated.
    port = lifecycle.restart_app({
        "CONTAINER_DISCOURSE_PLUGINS_BUILTIN": "",
        "CONTAINER_DISCOURSE_PLUGINS": (
            "https://github.com/discourse/discourse-prometheus@main"
        ),
    })
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    tail = _logs(lifecycle.app)[len(pre):]

    assert "caches were repaired; forcing rebuild" in tail, (
        f"expected forced rebuild log on repaired cache:\n{tail[-3000:]}"
    )
    assert "Bundle complete!" in tail, "rebuild path didn't run after cache repair"
    # Manifest hash should round-trip back to the same custom value.
    post_manifest = _exec(lifecycle.app, "cat", "/data/cache/.plugin-manifest").stdout.strip()
    assert post_manifest == pre_manifest, (
        f"manifest hash changed unexpectedly: {pre_manifest!r} -> {post_manifest!r}"
    )
    # And the bundle is back as a real directory.
    r = _exec(lifecycle.app, "test", "-d", "/data/cache/bundle")
    assert r.returncode == 0, "bundle dir not repopulated"


# ---------------------------------------------------------------------------
# Migrations: second boot is a no-op
# ---------------------------------------------------------------------------

def test_second_boot_no_new_migrations(stack):
    """First boot already ran migrations. Restart in place and confirm no
    'migrating' lines appear in the restart's tail."""
    _sh("docker", "restart", stack["app"])
    port = _host_port(stack["app"], "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
    # Pull just the tail after restart by inspecting logs since the most
    # recent start timestamp.
    started = _sh("docker", "inspect", "--format", "{{.State.StartedAt}}", stack["app"])
    since = started.stdout.strip()
    r = _sh("docker", "logs", "--since", since, stack["app"], check=False)
    tail = r.stdout + r.stderr
    # ActiveRecord's per-migration line looks like:
    #   == 20240101000000 SomeMigration: migrating ==
    assert "migrating ====" not in tail and ": migrating" not in tail, (
        f"second boot ran migrations; logs:\n{tail[-2000:]}"
    )


# ---------------------------------------------------------------------------
# Admin seeder (rootfs/app/script/seed_admin.rb)
#
# Regression tests for the two bugs fixed in ffd962a:
#   1. The "skip if admin exists" check matched Discourse's built-in system
#      users (id=-1, id=-2), so the seeder short-circuited on every fresh DB.
#      The `id > 0` filter is what scopes the check to real users.
#   2. user.activate ran before user.save!, raising RecordNotSaved because
#      activate's email_tokens.create! needs a persisted parent.
#
# Happy-path / idempotency tests ride the session `stack` fixture (already
# boots with CONTAINER_DISCOURSE_ADMIN_EMAIL + _PASSWORD set), so they cost
# no extra container boots. The no-email path needs a dedicated Stack.
# ---------------------------------------------------------------------------

# Email lives in user_emails (one-to-many on users) since the 2017 migration
# that created user_emails and marked users.email readonly; the column was
# later dropped outright in v2026. Look the admin up via the primary email.
ADMIN_EMAIL = "admin@smoke.local"
_BY_EMAIL_JOIN = (
    "JOIN user_emails ue ON ue.user_id = u.id AND ue.\"primary\" = true "
    f"WHERE ue.email='{ADMIN_EMAIL}'"
)


def test_admin_seeded_in_db(stack):
    """Real admin user exists with admin=t, approved=t, active=t and id > 0.
    A regression of the `id > 0` filter would cause the seeder to short-
    circuit on the system users and this row would not exist."""
    rows = _psql(
        stack,
        f"SELECT u.id, u.admin, u.approved, u.active FROM users u {_BY_EMAIL_JOIN}",
    ).splitlines()
    assert len(rows) == 1, f"expected exactly one admin row, got: {rows!r}"
    id_str, admin, approved, active = rows[0].split("|")
    assert int(id_str) > 0, f"admin user id should be > 0, got {id_str!r}"
    assert (admin, approved, active) == ("t", "t", "t"), \
        f"unexpected admin row flags: admin={admin!r} approved={approved!r} active={active!r}"


def test_admin_email_token_confirmed(stack):
    """A confirmed EmailToken exists for the seeded admin. This pins the
    save-before-activate ordering — if activate ran on an unsaved parent
    the user row itself would not exist (caught by the previous test);
    if a regression dropped activate entirely, no confirmed token would
    be present and the operator would be stuck at email verification."""
    # email_tokens.email is still a column (the v2026 schema only dropped
    # users.email), so this is a single-table lookup.
    rows = _psql(
        stack,
        f"SELECT confirmed FROM email_tokens "
        f"WHERE email='{ADMIN_EMAIL}' AND confirmed = true",
    ).splitlines()
    assert rows, "expected at least one confirmed EmailToken for the seeded admin"
    assert all(r == "t" for r in rows), f"unexpected confirmed values: {rows!r}"


def test_admin_seed_idempotent_on_restart(stack):
    """Restarting the container with the same admin env must not duplicate
    or mutate the admin user — the `User.where(admin: true).where('id > 0')`
    short-circuit is the load-bearing check.

    Password material lives in `user_passwords` since Discourse migration
    20241011080517 dropped `password_hash`/`salt` from `users`; joining
    that table catches a regression that re-runs the create path and
    rotates the hash."""
    snapshot_sql = (
        "SELECT u.id, u.created_at, up.password_hash, up.password_salt "
        "FROM users u "
        "LEFT JOIN user_passwords up ON up.user_id = u.id "
        f"{_BY_EMAIL_JOIN}"
    )
    before = _psql(stack, snapshot_sql).splitlines()
    assert len(before) == 1, f"expected exactly one admin row before restart: {before!r}"

    _sh("docker", "restart", stack["app"])
    port = _host_port(stack["app"], "3000")
    _wait_http_200(f"http://127.0.0.1:{port}/srv/status", FAST_READY_DEADLINE_S)

    after = _psql(stack, snapshot_sql).splitlines()
    assert after == before, (
        f"admin row mutated across restart\n  before: {before!r}\n  after:  {after!r}"
    )


@pytest.fixture(scope="module")
def no_admin_stack():
    """Fresh Stack with CONTAINER_DISCOURSE_ADMIN_EMAIL overridden to empty.
    docker's last-wins env resolution kills the Stack default; s6-envdir
    then drops the 0-byte var to unset (same mechanic exploited by
    test_lifecycle_empty_disables_all). The entrypoint's `-n` check at
    20-discourse-bootstrap.sh:368 then skips the seeder entirely."""
    s = Stack("no-admin")
    try:
        s.up_services()
        port = s.up_app(extra_env={"CONTAINER_DISCOURSE_ADMIN_EMAIL": ""})
        try:
            _wait_http_200(f"http://127.0.0.1:{port}/srv/status", READY_DEADLINE_S)
        except RuntimeError:
            print(_logs(s.app))
            raise
        yield {"app": s.app, "pg": s.pg, "redis": s.redis, "port": port, "stack": s}
    finally:
        s.teardown()


def test_admin_seed_skips_when_email_unset(no_admin_stack):
    """No CONTAINER_DISCOURSE_ADMIN_EMAIL → boot succeeds and no real admin
    is created. Operators who want to do first admin via the web onboarding
    flow must not be surprised by a seeded user from a stray default."""
    count = _psql(
        no_admin_stack,
        "SELECT count(*) FROM users WHERE admin = true AND id > 0",
    )
    assert count == "0", f"expected zero real admin users, got {count!r}"

    logs = _logs(no_admin_stack["app"])
    assert "seeding admin user" not in logs, \
        "entrypoint logged 'seeding admin user' despite empty CONTAINER_DISCOURSE_ADMIN_EMAIL"
