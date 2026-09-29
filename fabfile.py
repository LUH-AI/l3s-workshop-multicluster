"""Fabric pipeline - provides the runtime environment on every cluster.

The image built from the Dockerfile is only the *environment* (Python +
SMAC/PyExperimenter), not the project code. Its tag is a hash of the files
that define it (Dockerfile + requirements.txt), e.g. `env-3f9a1c0b7d2e`, so:

  - a new image is only built and pushed when one of those files changes,
  - a cluster is only pulled to when it doesn't have that environment yet.

Clusters come from config/clusters.json plus, if present, the gitignored
config/clusters.local.json (your own entries/overrides, merged per cluster).
Per cluster, the "type" field picks the runtime:

    "cluster-a": { ..., "type": "docker" }     -> docker pull <image>
    "luis":      { ..., "type": "apptainer" }  -> apptainer pull project_<tag>.sif

After a successful pull each cluster keeps exactly the current environment:
older project_*.sif files (apptainer) / older tags of the image (docker) are
removed. The pull is recorded in ~/.deployed_tag, which `fab verify` reads.

Usage (pip install -r requirements-dev.txt, then from the repo root):

    fab release                              # build if needed, deploy where needed, verify
    fab release --cluster cluster-a          # ... only Cluster A
    fab build [--force] [--platforms linux/amd64]
    fab deploy [--cluster cluster-a,luis] [--force] [--run]
    fab verify [--cluster cluster-a]
    fab clusters                             # configured clusters + runtime
    fab tag                                  # current environment tag
    fab install-hooks                        # automatic release on env changes (see below)

--cluster takes one name or a comma-separated list; without it every
cluster in clusters.json is targeted. --tag (all tasks) overrides the
computed environment tag, e.g. to roll back to an older one.

Automatic: `fab install-hooks` activates the git hooks in .githooks/. After
every commit, merge/pull or rebase that touches ENV_FILES they run
`fab release` in the background for the clusters in
`git config multicluster.autoClusters` (default: cluster-a - HPC clusters
only on purpose, since a new .sif replaces the one running experiments
use; set it to e.g. "cluster-a,luis" or "all"). Log: .fab-release.log.
Hooks don't see your shell's exports, so for them REGISTRY can also be set
as `git config multicluster.registry ghcr.io/<owner>/project`.

Auth: SSH uses your ssh-agent (ssh-add ~/workshop-keys/runner_key), falling
back to the "key" file from clusters.json if it exists. GHCR: set
GHCR_TOKEN (and optionally GHCR_USER, default = repo owner) to log in for
the push and for pulls of a private package; without it the push uses your
existing `docker login ghcr.io` and pulls run unauthenticated.
"""
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from fabric import Connection, task
from invoke.exceptions import Exit

# Keep our own messages in order with the streamed command output when
# stdout is a pipe or log file.
sys.stdout.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parent
CONFIG_FILE = ROOT / "config" / "clusters.json"
# Personal, gitignored additions/overrides (e.g. your own LUIS username),
# merged per cluster over clusters.json - so a shared repo's config stays
# untouched.
LOCAL_CONFIG_FILE = ROOT / "config" / "clusters.local.json"
# Everything that goes into the image - the environment tag hashes these.
# Add a file here if the Dockerfile starts COPYing it.
ENV_FILES = ("Dockerfile", "requirements.txt")
RUNTIMES = ("docker", "apptainer")
DEFAULT_PLATFORMS = "linux/amd64,linux/arm64"
# Dedicated buildx builder (docker-container driver) - the default "docker"
# driver can't build multi-arch images. Created on first `fab build`.
BUILDER = "multicluster"
# See scripts/deploy.sh: a non-interactive SSH command skips the login
# profile, which on LUIS holds the mandatory HTTPS proxy.
REMOTE_PROFILE = "[ -r /etc/profile ] && . /etc/profile > /dev/null 2>&1; "


# --- config / helpers -------------------------------------------------------

def load_clusters():
    clusters = json.loads(CONFIG_FILE.read_text())
    if LOCAL_CONFIG_FILE.exists():
        for name, cfg in json.loads(LOCAL_CONFIG_FILE.read_text()).items():
            clusters[name] = {**clusters.get(name, {}), **cfg}
    for name, cfg in clusters.items():
        missing = [k for k in ("host", "user", "type") if k not in cfg]
        if missing:
            raise Exit(f"ERROR: cluster '{name}' (clusters.json + clusters.local.json) is missing {missing}")
        if cfg["type"] not in RUNTIMES:
            raise Exit(f"ERROR: cluster '{name}' has type '{cfg['type']}' - expected one of {RUNTIMES}")
    return clusters


def select_clusters(clusters, cluster):
    """`cluster` is None (= all), one name, or a comma-separated list."""
    if not cluster:
        return list(clusters)
    names = [n.strip() for n in cluster.split(",") if n.strip()]
    unknown = [n for n in names if n not in clusters]
    if unknown:
        raise Exit(f"ERROR: unknown cluster(s) {unknown} - configured: {list(clusters)}")
    return names


def env_tag():
    """env-<hash of ENV_FILES> - same content, same tag, on every machine."""
    h = hashlib.sha256()
    for name in ENV_FILES:
        h.update(name.encode() + b"\0" + (ROOT / name).read_bytes() + b"\0")
    return f"env-{h.hexdigest()[:12]}"


def resolve_tag(tag):
    tag = tag or env_tag()
    # The tag ends up in remote shell commands and file names.
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
        raise Exit(f"ERROR: invalid image tag '{tag}'")
    return tag


def git(*args):
    """stdout of a git command in the repo ('' on failure)."""
    return subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True).stdout.strip()


def registry():
    """ghcr.io/<owner>/project, owner derived from origin like deploy.sh.

    Overrides: $REGISTRY, then `git config multicluster.registry` (for the
    hooks, which don't see your shell's exports).
    """
    override = os.environ.get("REGISTRY") or git("config", "multicluster.registry")
    if override:
        return override
    url = git("remote", "get-url", "origin")
    m = re.match(r"^(?:https://|git@)github\.com[:/]([^/]+)/", url)
    if not m:
        raise Exit(f"ERROR: can't derive the GHCR owner from origin ('{url}') - set REGISTRY=ghcr.io/<owner>/project")
    return f"ghcr.io/{m.group(1).lower()}/project"


def ghcr_credentials():
    """(user, token) if GHCR_TOKEN is set, else None."""
    token = os.environ.get("GHCR_TOKEN")
    if not token:
        return None
    user = os.environ.get("GHCR_USER") or registry().split("/")[1]
    return user, token


def local_ghcr_login(c):
    creds = ghcr_credentials()
    if creds:
        c.run(f"docker login ghcr.io -u {shlex.quote(creds[0])} --password-stdin",
              in_stream=io.StringIO(creds[1]), hide=True)


def image_in_registry(c, image):
    return c.run(f"docker buildx imagetools inspect {image}", hide=True, warn=True).ok


def connect(cfg):
    connect_kwargs = {}
    key = Path(cfg.get("key", "")).expanduser()
    if cfg.get("key") and key.is_file():
        connect_kwargs["key_filename"] = str(key)
    return Connection(
        cfg["host"],
        user=cfg["user"],
        port=int(cfg.get("port", 22)),
        connect_timeout=10,
        connect_kwargs=connect_kwargs,
    )


def banner(text):
    print(f"\n=== {text} " + "=" * max(0, 70 - len(text)))


# --- remote commands ---------------------------------------------------------

def has_env_command(cfg, image_repo, tag):
    """Exit 0 if the cluster already has this environment."""
    marker = f"[ \"$(cat ~/.deployed_tag 2>/dev/null)\" = '{tag}' ]"
    if cfg["type"] == "docker":
        return f"{marker} && docker image inspect {image_repo}:{tag} > /dev/null 2>&1"
    return f"{marker} && [ -f project_{tag}.sif ]"


def pull_command(cfg, image_repo, tag, creds, run_after):
    """Shell command for the cluster, chosen by its "type" in clusters.json."""
    image = f"{image_repo}:{tag}"
    mark_deployed = f"echo '{tag}' > ~/.deployed_tag"
    user = shlex.quote(creds[0]) if creds else None

    if cfg["type"] == "docker":
        if creds:
            # Throwaway DOCKER_CONFIG, removed whether or not the pull succeeds.
            cmd = (
                f"D=$(mktemp -d) && DOCKER_CONFIG=$D docker login ghcr.io -u {user} --password-stdin > /dev/null"
                f' && DOCKER_CONFIG=$D docker pull {image}; RC=$?; rm -rf "$D"; [ $RC -eq 0 ]'
            )
        else:
            cmd = f"docker pull {image}"
        cmd += f" && {mark_deployed}"
        # Keep only the current environment. Images still used by a
        # container can't be removed - that's fine, they go next time.
        cmd += (
            f" && {{ for i in $(docker images --format '{{{{.Repository}}}}:{{{{.Tag}}}}' {image_repo});"
            f" do if [ \"$i\" != '{image}' ] && docker rmi \"$i\" > /dev/null 2>&1; then echo \"removed $i\"; fi; done; }}"
        )
        if run_after:
            cmd += f" && docker run --rm {image}"
        return cmd

    # apptainer
    cmd = ""
    if creds:
        cmd = (
            "IFS= read -r APPTAINER_DOCKER_PASSWORD && "
            f"export APPTAINER_DOCKER_PASSWORD APPTAINER_DOCKER_USERNAME={user} && "
        )
    cmd += f"apptainer pull --force project_{tag}.sif docker://{image}"
    cmd += " && unset APPTAINER_DOCKER_PASSWORD APPTAINER_DOCKER_USERNAME"
    # Keep exactly the current .sif so the home quota doesn't fill up.
    cmd += f" && find . -maxdepth 1 -name 'project_*.sif' ! -name 'project_{tag}.sif' -print -delete"
    cmd += f" && {mark_deployed}"
    if run_after:
        cmd += f" && apptainer run project_{tag}.sif"
    return cmd


def deploy_one(name, cfg, image_repo, tag, run_after, force):
    banner(f"deploy {name} ({cfg['type']}) <- {image_repo}:{tag}")
    creds = ghcr_credentials()
    try:
        with connect(cfg) as conn:
            if not force and conn.run(REMOTE_PROFILE + has_env_command(cfg, image_repo, tag),
                                      hide=True, warn=True).ok:
                print(f"✓ {name} already has {tag} - nothing to pull")
                if run_after:
                    run = f"docker run --rm {image_repo}:{tag}" if cfg["type"] == "docker" else f"apptainer run project_{tag}.sif"
                    return conn.run(REMOTE_PROFILE + run, warn=True).ok
                return True
            # The token only ever travels over stdin, never on the command line.
            result = conn.run(
                REMOTE_PROFILE + pull_command(cfg, image_repo, tag, creds, run_after),
                in_stream=io.StringIO(creds[1] + "\n" if creds else ""),
                warn=True,
            )
    except Exception as e:  # SSH/auth/network errors - keep going with the other clusters
        print(f"✗ {name}: {type(e).__name__}: {e}")
        return False
    if result.ok:
        print(f"✓ {name} now has {tag}")
    else:
        print(f"✗ Deployment to {name} failed (exit {result.exited})")
    return result.ok


def deployed_tag(cfg):
    """Tag recorded by the last successful deploy, or None."""
    with connect(cfg) as conn:
        tag = conn.run("cat ~/.deployed_tag 2>/dev/null", hide=True, warn=True).stdout.strip()
    return tag or None


# --- pipeline steps (shared by the tasks) -------------------------------------

def run_build(c, tag, platforms, force):
    image = f"{registry()}:{tag}"
    local_ghcr_login(c)
    if not force and image_in_registry(c, image):
        print(f"✓ {image} already in GHCR - environment unchanged, nothing to build")
        return

    banner(f"build {image} ({platforms})")
    if not c.run(f"docker buildx inspect {BUILDER}", hide=True, warn=True).ok:
        c.run(f"docker buildx create --name {BUILDER} --driver docker-container")
    c.run(
        f"docker buildx build --builder {BUILDER} --platform {shlex.quote(platforms)}"
        f" --build-arg ENV_TAG={tag} -t {image} --push {shlex.quote(str(ROOT))}"
    )
    print(f"✓ Pushed {image}")


def run_deploy(clusters, names, tag, run_after, force):
    image_repo = registry()
    results = {n: deploy_one(n, clusters[n], image_repo, tag, run_after, force) for n in names}
    return all(results.values()), results


def run_verify(clusters, names, tag):
    banner(f"verify (expected environment {tag})")
    print(f"{'CLUSTER':<14} {'RUNTIME':<10} {'DEPLOYED':<18} STATUS")
    ok = True
    for name in names:
        cfg = clusters[name]
        try:
            running = deployed_tag(cfg)
        except Exception:
            running, status = "-", "UNREACHABLE ✗"
        else:
            if running is None:
                running, status = "-", "NO DEPLOYMENT ✗"
            elif running == tag:
                status = "✓"
            else:
                status = "OUTDATED ✗"
        ok &= status == "✓"
        print(f"{name:<14} {cfg['type']:<10} {running:<18} {status}")
    print("\nAll clusters have the current environment." if ok
          else "\nAt least one cluster is outdated or unreachable.")
    return ok


def run_release(c, cluster, tag, run, force, platforms):
    """build (if needed) + deploy (where needed) + verify; True if all ok."""
    all_clusters = load_clusters()
    names = select_clusters(all_clusters, cluster)
    tag = resolve_tag(tag)

    run_build(c, tag, platforms, force)
    deploy_ok, results = run_deploy(all_clusters, names, tag, run, force)
    verify_ok = run_verify(all_clusters, names, tag)
    print_summary(results)
    return deploy_ok and verify_ok


def notify(message):
    """macOS notification for background runs; silently skipped elsewhere."""
    if shutil.which("osascript"):
        subprocess.run(["osascript", "-e", f"display notification {json.dumps(message)} with title \"fab release\""],
                       capture_output=True)


def print_summary(results):
    banner("summary")
    for name, ok in results.items():
        print(f"  {'✓' if ok else '✗'} {name}")


# --- tasks --------------------------------------------------------------------

TAG_HELP = "Environment tag (default: hash of Dockerfile + requirements.txt)"
CLUSTER_HELP = "Cluster name or comma-separated list (default: all)"


@task
def clusters(c):
    """List the configured clusters and their runtime (docker/apptainer)."""
    for name, cfg in load_clusters().items():
        print(f"{name:<14} {cfg['type']:<10} {cfg['user']}@{cfg['host']}:{cfg.get('port', 22)}")


@task
def tag(c):
    """Print the current environment tag and the image it maps to."""
    print(f"{registry()}:{env_tag()}")


@task(help={
    "tag": TAG_HELP,
    "platforms": f"buildx platforms (default: {DEFAULT_PLATFORMS})",
    "force": "Build and push even if the tag is already in GHCR",
})
def build(c, tag=None, platforms=DEFAULT_PLATFORMS, force=False):
    """Build the environment image and push it to GHCR (skipped if already there)."""
    run_build(c, resolve_tag(tag), platforms, force)


@task(help={
    "cluster": CLUSTER_HELP,
    "tag": TAG_HELP,
    "run": "Run the environment smoke test on the cluster afterwards",
    "force": "Pull even if the cluster already has this environment",
})
def deploy(c, cluster=None, tag=None, run=False, force=False):
    """Pull the environment onto the cluster(s) that don't have it yet."""
    all_clusters = load_clusters()
    names = select_clusters(all_clusters, cluster)
    ok, results = run_deploy(all_clusters, names, resolve_tag(tag), run, force)
    print_summary(results)
    if not ok:
        raise Exit(code=1)


@task(help={"cluster": CLUSTER_HELP, "tag": TAG_HELP})
def verify(c, cluster=None, tag=None):
    """Check that each cluster has the current environment."""
    all_clusters = load_clusters()
    names = select_clusters(all_clusters, cluster)
    if not run_verify(all_clusters, names, resolve_tag(tag)):
        raise Exit(code=1)


@task(help={
    "cluster": CLUSTER_HELP,
    "tag": TAG_HELP,
    "run": "Run the environment smoke test on the cluster(s) afterwards",
    "force": "Rebuild and re-pull even if nothing changed",
    "platforms": f"buildx platforms (default: {DEFAULT_PLATFORMS})",
})
def release(c, cluster=None, tag=None, run=False, force=False, platforms=DEFAULT_PLATFORMS):
    """Build if needed, deploy where needed, verify."""
    if not run_release(c, cluster, tag, run, force, platforms):
        raise Exit(code=1)


# --- automatic release via git hooks -------------------------------------------

GIT_DIR = Path(git("rev-parse", "--absolute-git-dir") or ROOT / ".git")
# One background release at a time; a trigger that arrives meanwhile sets
# PENDING, and the running one goes again once it's done.
LOCK_DIR = GIT_DIR / "fab-auto.lock"
PENDING = GIT_DIR / "fab-auto.pending"


def acquire_lock():
    try:
        LOCK_DIR.mkdir()
    except FileExistsError:
        pid_file = LOCK_DIR / "pid"
        try:
            os.kill(int(pid_file.read_text()), 0)
            return False  # another release is running
        except (OSError, ValueError):
            shutil.rmtree(LOCK_DIR, ignore_errors=True)  # stale lock
            return acquire_lock()
    (LOCK_DIR / "pid").write_text(str(os.getpid()))
    return True


@task(help={"base": "Revision to diff HEAD against (set by the hook)"})
def auto_release(c, base):
    """(Called by the git hooks) release if <base>..HEAD changed ENV_FILES."""
    changed = set(git("diff", "--name-only", base, "HEAD").splitlines())
    touched = sorted(changed & set(ENV_FILES))
    if not touched:
        return
    print(f"\n##### {datetime.now():%Y-%m-%d %H:%M:%S} - {', '.join(touched)} changed ({base[:7]}..HEAD)")

    # Half-done edits would end up in the image under a tag that matches no
    # commit - wait for them to be committed (that commit triggers again).
    dirty = git("status", "--porcelain", "--", *ENV_FILES)
    if dirty:
        print(f"skipped: uncommitted changes in environment files:\n{dirty}")
        return

    if not acquire_lock():
        PENDING.touch()
        print("another release is running - it will run again afterwards")
        return
    try:
        auto = os.environ.get("FAB_AUTO_CLUSTERS") or git("config", "multicluster.autoClusters") or "cluster-a"
        while True:
            PENDING.unlink(missing_ok=True)
            try:
                ok = run_release(c, None if auto == "all" else auto, None, False, False, DEFAULT_PLATFORMS)
            except Exception as e:  # includes Exit from config/tag errors
                print(f"✗ {type(e).__name__}: {e}")
                ok = False
            notify(f"{env_tag()} on {auto}: {'ok' if ok else 'FAILED - see .fab-release.log'}")
            if not PENDING.exists():
                break
            print(f"\n##### {datetime.now():%Y-%m-%d %H:%M:%S} - new environment change arrived, releasing again")
    finally:
        shutil.rmtree(LOCK_DIR, ignore_errors=True)


@task
def install_hooks(c):
    """Activate .githooks/ (auto-release on environment changes) for this clone."""
    fab_bin = shutil.which(sys.argv[0]) or os.path.abspath(sys.argv[0])
    if not os.access(fab_bin, os.X_OK):
        raise Exit(f"ERROR: can't locate the fab executable ('{fab_bin}') - run this as `fab install-hooks`")
    own = [p.name for p in (GIT_DIR / "hooks").glob("*") if not p.name.endswith(".sample")]
    if own and not git("config", "core.hooksPath"):
        print(f"WARNING: core.hooksPath disables your existing .git/hooks: {own}")
    for hook in (ROOT / ".githooks").iterdir():
        hook.chmod(0o755)
    c.run("git config core.hooksPath .githooks")
    # Hooks run without your shell's PATH (e.g. commits from the IDE).
    c.run(f"git config multicluster.fab {shlex.quote(fab_bin)}")
    auto = git("config", "multicluster.autoClusters") or "cluster-a (default)"
    print(f"✓ Hooks active. fab: {fab_bin}")
    print(f"  Auto-release targets: {auto}  (git config multicluster.autoClusters <a,b|all>)")
    print(f"  Registry: {registry()}  (git config multicluster.registry <...> to override)")
    print("  Log: .fab-release.log. Disable: git config --unset core.hooksPath")
