# Project Setup Guide

Everything a participant needs to go from a fresh machine to a working
development environment. Complete this **before** the workshop session.

---

## 1. System requirements

### Operating system

macOS or Linux. Windows works **only via WSL2** with Docker Desktop's
WSL backend — run all commands inside the WSL terminal, not PowerShell
or Git Bash.

### Required system tools

Install these first. Everything else depends on them.

| Tool | macOS | Ubuntu/Debian | Verify |
|---|---|---|---|
| **Git** | `brew install git` | `sudo apt install git` | `git --version` |
| **Docker** | [Docker Desktop for Mac](https://docs.docker.com/desktop/install/mac-install/) | [Docker Engine](https://docs.docker.com/engine/install/ubuntu/) or [Docker Desktop](https://docs.docker.com/desktop/install/linux/) | `docker info` |
| **jq** | `brew install jq` | `sudo apt install jq` | `jq --version` |
| **rsync** | pre-installed | `sudo apt install rsync` | `rsync --version` |
| **SSH** | pre-installed | `sudo apt install openssh-client` | `ssh -V` |

> **Docker note:** On Linux, add your user to the `docker` group
> (`sudo usermod -aG docker $USER`, then log out and back in) so you
> can run `docker` without `sudo`. The scripts do not use `sudo`.

### Optional system tools (for WP2 participants)

| Tool | Install | Verify |
|---|---|---|
| **Ansible** | `pip install ansible` or `brew install ansible` | `ansible --version` |

### Optional system tools (for multi-cluster PyExperimenter with MySQL)

| Tool | Install | Verify |
|---|---|---|
| **MySQL client libs** | macOS: `brew install mysql-client` / Ubuntu: `sudo apt install libmysqlclient-dev` | `mysql_config --version` |

These are only needed if your PyExperimenter config uses MySQL instead
of SQLite. For local development and single-cluster testing, SQLite
works without any extra system packages.

---

## 2. Python environment

### Python version

**Python 3.10** is required. SMAC and PyExperimenter are tested against
3.10; newer versions may cause dependency resolution failures with
SMAC's pinned sub-dependencies.

Check your version:

```bash
python3 --version   # should print Python 3.10.x
```

If you have a different version, use `pyenv`, `conda`, or `pixi` to
install 3.10 alongside it:

```bash
# Option A: pyenv
pyenv install 3.10.14
pyenv local 3.10.14

# Option B: conda / mamba
conda create -n workshop python=3.10
conda activate workshop

# Option C: pixi
pixi init --python 3.10
pixi shell
```

### Install Python dependencies

The project has two requirements files:

| File | Purpose | Who needs it |
|---|---|---|
| `requirements.txt` | In-container packages (SMAC, PyExperimenter) — also useful locally for testing | Everyone |
| `requirements-dev.txt` | Local tooling (Fabric, Jinja2, Ansible, etc.) | WP2 participants + anyone extending the allocator |

Install both:

```bash
pip install -r requirements.txt
pip install -r requirements-dev.txt
```

> **Tip:** If `pip install smac` fails with a build error, you're
> likely missing `swig` and a C++ compiler:
>
> ```bash
> # macOS
> brew install swig
> # Ubuntu/Debian
> sudo apt install swig g++
> ```

### Verify Python packages

```bash
python3 -c "import smac; print('smac', smac.__version__)"
python3 -c "import py_experimenter; print('py_experimenter OK')"
python3 -c "import jinja2; print('jinja2', jinja2.__version__)"
python3 -c "import fabric; print('fabric', fabric.__version__)"  # WP2 only
```

---

## 3. Repository setup

### Fork and clone

```bash
# 1. Fork the repo on GitHub (click the Fork button)
# 2. Clone your fork
git clone git@github.com:<your-username>/l3s-workshop-multicluster.git
cd l3s-workshop-multicluster
```

### SSH keys for cluster access

Generate a dedicated key pair for the workshop:

```bash
mkdir -p ~/workshop-keys
ssh-keygen -t ed25519 -f ~/workshop-keys/runner_key -N ""
```

Load it into your SSH agent:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/workshop-keys/runner_key
```

> **This must be done every time you open a new terminal.** The agent
> doesn't persist across reboots. If `preflight.sh` reports
> `FAIL - ssh-agent has at least one key loaded`, this is why.

### GitHub secrets

In your fork's Settings → Secrets and variables → Actions, create:

| Secret name | Value |
|---|---|
| `GHCR_TOKEN` | A classic PAT with `write:packages` scope ([create one here](https://github.com/settings/tokens/new)) |
| `SSH_PRIVATE_KEY` | Contents of `~/workshop-keys/runner_key` (the private key, not `.pub`) |

### Self-hosted runner

The CI workflows run on a self-hosted runner (your laptop), not
GitHub's hosted runners.

1. Go to your fork → Settings → Actions → Runners → New self-hosted runner
2. Follow GitHub's instructions for your OS (download, configure, run)
3. Start the runner: `./run.sh` (or install as a service with `./svc.sh install`)
4. Verify: Settings → Actions → Runners should show status **Idle**

### GHCR package visibility

After the first successful `build.yml` run pushes an image:

1. Go to your GitHub profile → Packages
2. Click the `project` package
3. Settings → Change visibility → **Public**

Without this, `deploy.sh` can't pull the image on the clusters.

---

## 4. Local cluster simulator (Cluster A)

The Docker-based simulator lets you test the full pipeline without
SSH-ing into a real HPC cluster.

```bash
./cluster-config/local-docker.sh cluster-a ~/workshop-keys/runner_key.pub
```

Verify it's running:

```bash
docker ps                           # should show a 'cluster-a' container
ssh -p 2222 clustera@localhost "echo ok"   # should print 'ok'
```

---

## 5. End-to-end smoke test

Run these in order. If any step fails, fix it before moving on.

```bash
# 1. Preflight: checks all tools and connectivity
./scripts/preflight.sh

# 2. Build the container image locally
docker build -t test-build .

# 3. Trigger the CI build (push anything to your fork)
git commit --allow-empty -m "trigger build"
git push

# 4. Wait for build.yml to pass (check Actions tab)

# 5. Deploy to the simulator
./scripts/deploy.sh cluster-a <your-image-tag>
# (image tag = the short git SHA, visible in the build.yml output)

# 6. Verify the deployment
./scripts/verify.sh <your-image-tag> cluster-a
```

If all six steps pass, you're ready for the workshop.

---

## 6. Real cluster access (optional before the session)

If you have SSH access to LUIS, KISSKI, or PC2, you can set them up
now. See `doc/clusters.md` for per-cluster connection details, storage
layouts, and one-time setup steps.

Add your cluster to `config/clusters.json`:

```json
{
  "cluster-a": { ... },
  "luis": {
    "host": "login.luis.uni-hannover.de",
    "port": 22,
    "user": "<your-username>",
    "key": "~/workshop-keys/runner_key",
    "type": "apptainer",
    "sync_path": "/home/<your-username>/workshop"
  }
}
```

Then test:

```bash
./scripts/preflight.sh              # should show luis as reachable
./scripts/deploy.sh luis <tag>      # pull the image
./scripts/verify.sh <tag> luis      # confirm it landed
```

---

## 7. Project structure reference

```
l3s-workshop-multicluster/
├── .github/workflows/         # CI: build, deploy, sync, health, test_runner
├── cluster-config/
│   └── local-docker.sh        # Cluster A simulator setup
├── config/
│   ├── clusters.json          # Cluster connection profiles
│   └── experiment_config.yaml # PyExperimenter grid definition
├── doc/                       # Design docs (WP1, WP2, WP3, clusters)
├── generated/                 # Rendered sbatch scripts (gitignored)
├── scripts/
│   ├── preflight.sh           # Pre-session diagnostic
│   ├── deploy.sh              # Pull image to a cluster
│   ├── verify.sh              # Confirm deployment
│   ├── sync.sh                # Rsync files to a cluster
│   └── create-deployment-info.sh
├── src/
│   ├── smac_worker.py         # SMAC benchmark worker (PyExperimenter)
│   ├── cluster_state.py       # Query cluster capacity via SSH
│   ├── allocator.py           # Multi-cluster experiment allocator
│   └── llm_scheduler.py       # Optional LLM scheduling layer
├── templates/
│   └── job.sh.j2              # SLURM job template (Jinja2)
├── Dockerfile                 # Container image definition
├── requirements.txt           # In-container Python deps
├── requirements-dev.txt       # Local/participant Python deps
├── CONTRIBUTING.md            # Collaboration guidelines
├── deploy.sh                  # Root shim → scripts/deploy.sh
└── version.txt
```

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `pip install smac` fails with "swig not found" | Missing build tools | `brew install swig` (macOS) or `sudo apt install swig g++` (Ubuntu) |
| `docker info` says "permission denied" | User not in docker group | `sudo usermod -aG docker $USER`, then log out and back in |
| `ssh-add` says "Could not open connection to auth agent" | No ssh-agent running | `eval "$(ssh-agent -s)"` then `ssh-add ~/workshop-keys/runner_key` |
| `deploy.sh` says "denied: denied" on pull | GHCR package is private | GitHub profile → Packages → project → Settings → Public |
| `deploy.sh` says "cluster not found" | Cluster not in clusters.json | Add the entry (see section 6) |
| Preflight says cluster unreachable but `ssh` works manually | Key not in agent | `ssh-add ~/workshop-keys/runner_key` |
| `smac_worker.py` crashes with DB locked | SQLite + multiple workers | Switch to MySQL in `experiment_config.yaml` |
| Runner shows "Offline" in GitHub | `./run.sh` not running | Restart it, or install as a service |
