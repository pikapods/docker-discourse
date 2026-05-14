import json
import os
import re
import subprocess

import pytest

IMAGE = os.environ["IMAGE"]

DEFAULT_PLUGINS = [
    "checklist",
    "discourse-details",
    "discourse-narrative-bot",
    "discourse-presence",
    "discourse-reactions",
    "styleguide",
]


def _inspect():
    out = subprocess.run(
        ["docker", "inspect", IMAGE],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)[0]


@pytest.fixture(scope="session")
def inspect():
    return _inspect()


def _run(*args, check=False):
    return subprocess.run(
        ["docker", "run", "--rm", "--entrypoint=", IMAGE, *args],
        capture_output=True, text=True, check=check,
    )


class TestImageMetadata:
    def test_required_oci_labels(self, inspect):
        labels = inspect["Config"].get("Labels") or {}
        for key in (
            "org.opencontainers.image.source",
            "org.opencontainers.image.version",
            "org.opencontainers.image.licenses",
            "org.opencontainers.image.title",
        ):
            assert labels.get(key), f"missing OCI label: {key}"

    def test_runs_as_root_entrypoint(self, inspect):
        # The s6 /init must run as root to drop privileges per-service via
        # gosu. The discourse user is used by the s6 run scripts directly.
        user = inspect["Config"].get("User", "")
        assert user in ("", "0", "root"), f"expected root entrypoint, got {user!r}"

    def test_healthcheck_defined(self, inspect):
        assert inspect["Config"].get("Healthcheck"), "no Healthcheck defined"

    def test_exposes_3000(self, inspect):
        ports = inspect["Config"].get("ExposedPorts") or {}
        assert "3000/tcp" in ports, f"3000/tcp not exposed; got {list(ports)}"

    def test_image_size_under_limit(self, inspect):
        size_mb = inspect["Size"] / (1024 * 1024)
        # Retained build toolchain for runtime plugin install plus the full
        # bundled-plugin stash at /opt/discourse-plugins-core (50+ trees) put
        # the floor near 2.8 GB; 3.5 GB is the regression alarm.
        assert size_mb < 3584, f"image size {size_mb:.0f} MB exceeds 3.5 GB guardrail"

    def test_default_env_present(self, inspect):
        env = dict(e.split("=", 1) for e in inspect["Config"].get("Env") or [])
        assert env.get("RAILS_ENV") == "production"
        assert env.get("RAILS_LOG_TO_STDOUT") == "1"
        assert env.get("BUNDLE_PATH") == "/data/cache/bundle"
        assert env.get("CONTAINER_DISCOURSE_DB_MIGRATE") == "TRUE"
        assert env.get("CONTAINER_DISCOURSE_ENABLE_SIDEKIQ") == "TRUE"

    def test_entrypoint_is_s6_init(self, inspect):
        ep = inspect["Config"].get("Entrypoint") or []
        assert ep == ["/init"], f"unexpected entrypoint: {ep!r}"


class TestImageFilesystem:
    def test_discourse_user_exists(self):
        r = _run("id", "-u", "discourse")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "1000"

    @pytest.mark.parametrize("link,target", [
        ("/app/public/uploads", "/data/uploads"),
        ("/app/public/backups", "/data/backups"),
        ("/app/public/assets", "/data/cache/assets"),
    ])
    def test_data_symlinks(self, link, target):
        r = _run("readlink", link)
        assert r.returncode == 0, f"readlink {link} failed: {r.stderr}"
        assert r.stdout.strip() == target, f"{link} -> {r.stdout.strip()!r}, expected {target!r}"

    def test_data_dir_owned_by_discourse(self):
        r = _run("stat", "-c", "%U:%G", "/data")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "discourse:discourse"

    @pytest.mark.parametrize("binary", [
        "ruby", "bundle", "node", "pnpm", "gosu", "curl", "git", "rsync",
        "pg_isready", "redis-cli", "convert", "gcc", "make",
    ])
    def test_runtime_binaries_present(self, binary):
        r = _run("which", binary)
        assert r.returncode == 0, f"{binary} not found on PATH (stderr={r.stderr!r})"
        assert r.stdout.strip(), f"which {binary} returned empty"

    @pytest.mark.parametrize("path", [
        "/app/bin/rails",
        "/app/Gemfile",
        "/app/config/application.rb",
        "/app/baked-default-plugins",
        "/app/baked-plugin-manifest",
        "/usr/local/bin/discourse-manifest-hash",
        "/usr/local/bundle-baked",
        "/app/assets-baked",
    ])
    def test_required_files_present(self, path):
        r = _run("test", "-e", path)
        assert r.returncode == 0, f"{path} missing"

    def test_plugins_live_dir_empty(self):
        # Should be empty in the image — populated only by bootstrap at boot.
        r = _run("sh", "-c", "ls -A /app/plugins | wc -l")
        assert r.returncode == 0, r.stderr
        assert r.stdout.strip() == "0", f"/app/plugins not empty: {r.stdout!r}"

    def test_plugins_core_dir_populated(self):
        r = _run("sh", "-c", "ls -A /opt/discourse-plugins-core | wc -l")
        assert r.returncode == 0, r.stderr
        # Conservative floor; current main ships ~43. Plan promises ≥20.
        count = int(r.stdout.strip())
        assert count >= 20, f"/opt/discourse-plugins-core has only {count} entries"

    def test_narrative_bot_present_in_core(self):
        # Spot-check that bundled plugins moved cleanly: plugin.rb is the
        # canonical entry file for every Discourse plugin.
        r = _run("test", "-f", "/opt/discourse-plugins-core/discourse-narrative-bot/plugin.rb")
        assert r.returncode == 0, "discourse-narrative-bot/plugin.rb missing"

    def test_baked_default_plugins_contents(self):
        r = _run("cat", "/app/baked-default-plugins")
        assert r.returncode == 0, r.stderr
        names = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
        assert names == DEFAULT_PLUGINS, f"unexpected baked defaults: {names!r}"

    def test_baked_manifest_is_sha256(self):
        r = _run("cat", "/app/baked-plugin-manifest")
        assert r.returncode == 0, r.stderr
        digest = r.stdout.strip()
        assert re.fullmatch(r"[0-9a-f]{64}", digest), f"not a sha256: {digest!r}"

    def test_hash_helper_self_consistent(self):
        # Re-running the helper against the baked inputs must reproduce
        # the baked digest — proves build-time and runtime agree.
        r = _run(
            "sh", "-c",
            "/usr/local/bin/discourse-manifest-hash "
            "--builtin-file /app/baked-default-plugins --third-party-file /dev/null "
            "&& cat /app/baked-plugin-manifest"
        )
        assert r.returncode == 0, r.stderr
        lines = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
        assert len(lines) == 2, f"expected 2 hash lines, got {lines!r}"
        assert lines[0] == lines[1], f"baked hash drift: {lines!r}"

    def test_hash_helper_help_exits_zero(self):
        r = _run("/usr/local/bin/discourse-manifest-hash", "--help")
        assert r.returncode == 0, r.stderr

    @pytest.mark.parametrize("path", [
        "/etc/s6-overlay/s6-rc.d/discourse-bootstrap/type",
        "/etc/s6-overlay/s6-rc.d/discourse-bootstrap/up",
        "/etc/s6-overlay/s6-rc.d/discourse-web/run",
        "/etc/s6-overlay/s6-rc.d/discourse-web/type",
        "/etc/s6-overlay/s6-rc.d/discourse-web/dependencies.d/discourse-bootstrap",
        "/etc/s6-overlay/s6-rc.d/discourse-sidekiq/run",
        "/etc/s6-overlay/s6-rc.d/discourse-sidekiq/type",
        "/etc/s6-overlay/s6-rc.d/discourse-sidekiq/dependencies.d/discourse-bootstrap",
        "/etc/s6-overlay/s6-rc.d/user/contents.d/discourse-web",
        "/etc/s6-overlay/s6-rc.d/user/contents.d/discourse-sidekiq",
        "/etc/entrypoint.d/20-discourse-bootstrap.sh",
        "/init",
    ])
    def test_s6_files_present(self, path):
        r = _run("test", "-e", path)
        assert r.returncode == 0, f"{path} missing"

    @pytest.mark.parametrize("path", [
        "/etc/s6-overlay/s6-rc.d/discourse-bootstrap/up",
        "/etc/s6-overlay/s6-rc.d/discourse-web/run",
        "/etc/s6-overlay/s6-rc.d/discourse-sidekiq/run",
        "/etc/entrypoint.d/20-discourse-bootstrap.sh",
        "/usr/local/bin/discourse-manifest-hash",
    ])
    def test_s6_scripts_executable(self, path):
        r = _run("test", "-x", path)
        assert r.returncode == 0, f"{path} not executable"


# Marked runtime: a full image rebuild — slow.
@pytest.mark.runtime
class TestCustomUidRebuild:
    """Rebuild with --build-arg DISCOURSE_UID/GID and verify the new UID
    actually owns /data. Guard against the freescout-style trap where the
    chown step misses /data."""

    UID = "1500"
    GID = "1500"

    @pytest.fixture(scope="class")
    def image(self):
        ctx = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        tag = f"discourse-uid{self.UID}-test"
        r = subprocess.run(
            ["docker", "build",
             "--build-arg", f"DISCOURSE_UID={self.UID}",
             "--build-arg", f"DISCOURSE_GID={self.GID}",
             "-t", tag, ctx],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            pytest.fail(
                f"docker build failed (rc={r.returncode})\n"
                f"--- stdout ---\n{r.stdout}\n--- stderr ---\n{r.stderr}"
            )
        try:
            yield tag
        finally:
            subprocess.run(["docker", "rmi", "-f", tag], capture_output=True)

    def test_discourse_user_remapped(self, image):
        r = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint=", image, "id", "-u", "discourse"],
            capture_output=True, text=True, check=True,
        )
        assert r.stdout.strip() == self.UID

    def test_data_dir_remapped(self, image):
        r = subprocess.run(
            ["docker", "run", "--rm", "--entrypoint=", image, "stat", "-c", "%u:%g", "/data"],
            capture_output=True, text=True, check=True,
        )
        assert r.stdout.strip() == f"{self.UID}:{self.GID}"
