# Multicluster Workshop

A deployment pipeline that builds a container image from a private GitHub
repo via GitHub Actions, pushes it to GHCR, and rolls it out to multiple
heterogeneous target systems (two Docker clusters + LUIS via Apptainer).

## Architecture

```
                       GitHub
                         │
                    private repo
                         │
              ┌──────────┴──────────┐
              │                     │
        Build Docker Image      Source Code
              │                     │
              ▼                     │
            GHCR                    │
      ghcr.io/org/project           │
              │                     │
        ┌─────┼──────────┐          │
        ▼     ▼          ▼          │
 Cluster A  Cluster B    LUIS ◄─────┘
 Docker     Docker     Apptainer
```

## Repo structure

```
multicluster-workshop/
├── .github/workflows/
│   ├── deploy.yml          # workflow_dispatch, cluster selection, build + deploy
│   └── health.yml          # scheduled/manual verify run without deploying
├── config/
│   └── clusters.json       # central cluster definition (name, type, host, ...)
├── scripts/
│   ├── deploy.sh           # ./deploy.sh <cluster-name> <image-tag>
│   ├── verify.sh           # expected-vs-actual comparison across all clusters
│   ├── create-deployment-info.sh
│   ├── preflight.sh        # checks local tooling + SSH reachability
│   └── sync.sh             # optional rsync of src/ (kept separate from image deploy)
├── cluster-config/
│   ├── local-docker.sh     # generic local test target (sshd + docker)
│   ├── cluster-a-docker.sh # spin up the Cluster A stand-in locally
│   └── luis-apptainer.sh   # test pull+run against a real Apptainer system
├── src/hello.py
├── deploy.sh                # wrapper -> scripts/deploy.sh (so `./deploy.sh ...` works)
├── version.txt
├── requirements.txt
└── Dockerfile
```

Note: the original diagram's `cluster config/` became `cluster-config/`
(directory names can't contain spaces).

## Preparation

1. **Workshop repo**: create/push this repo as a private GitHub repo.
2. **Prepare the runner**: a dedicated GitHub Actions runner (self-hosted or
   GitHub-hosted, see the security section below), with access to `docker`,
   `jq`, `ssh`, `rsync`.
3. **Prepare target systems** - two local Docker containers standing in for
   Cluster A/B:

   ```
   ssh-keygen -t ed25519 -f ~/.ssh/id_cluster_a -N ""
   ./cluster-config/cluster-a-docker.sh ~/.ssh/id_cluster_a.pub
   # cluster-b analog: copy/adjust local-docker.sh cluster-b <port> <pubkey>
   ```

   Lock down the runner's access to the containers (see below).
4. Fill in `config/clusters.json` with real hosts/users.
5. **Test SSH**:

   ```
   ssh -p 2201 -i ~/.ssh/id_cluster_a deploy@127.0.0.1
   ./scripts/preflight.sh
   ```
6. Provide a **placeholder image** before the split, so Groups 1/3/4 don't
   have to wait on Group 2:

   ```
   docker build -t ghcr.io/<org>/<project>:dummy .
   docker push ghcr.io/<org>/<project>:dummy
   ```
7. Nail down the **Definition of Done per group** (see below) - **before**
   the split.
8. Nail down the **shared interfaces** (see table below) - **before** the
   split.

### Securing the runner's access to target systems

- Prefer SSH keys set up as **deploy keys with a `command=` restriction** in
  `authorized_keys`, e.g.:

  ```
  command="/opt/workshop/bin/remote-deploy.sh",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA... deploy@runner
  ```

  `remote-deploy.sh` inspects `$SSH_ORIGINAL_COMMAND` and only allows a
  fixed allowlist of commands (pull/run the image) instead of free shell
  access.
- Use **GitHub Environments** with protection rules per cluster
  (`cluster-a`, `cluster-b`, `luis`) instead of one repo-wide secret - each
  environment gets its own `CLUSTER_SSH_KEY`/credentials.
- A runner with Docker socket access is effectively root: use **rootless
  Docker** where possible, and don't share the runner with other workloads.
- Keep the GHCR package **private**, use a pull token with as narrow a
  scope as possible (`read:packages` instead of a full PAT), and inject the
  token only via the relevant environment (`GHCR_PULL_TOKEN`).

## Shared interfaces (fixed before the split)

| What                   | Format/convention                                                                              |
| ---------------------- | ---------------------------------------------------------------------------------------------- |
| Image naming           | `ghcr.io/org/project:<git-sha>`                                                              |
| Cluster identifiers    | as in`config/clusters.json`: `cluster-a`, `cluster-b`, `luis`                          |
| `deploy.sh` call     | `./deploy.sh <cluster-name> <image-tag>` → exit code 0/≠0                                  |
| `verify.sh` call     | reads`config/clusters.json`, returns a status table + exit code                              |
| Deployment info format | JSON with at least`commit`, `image_tag`, `timestamp` (see `create-deployment-info.sh`) |

### `deploy.sh` exit codes

| Code | Meaning                   |
| ---- | ------------------------- |
| 0    | success                   |
| 1    | local usage/config error  |
| 2    | unknown cluster name/type |
| 3    | cluster not reachable     |
| 4    | remote command failed     |

### Digest vs. tag

`verify.sh` compares **tags** by default (simple, but tags are mutable in
principle). For a solid guarantee that "the same code is really running
everywhere", also compare the **digest**:

```
# read the digest of the pushed image
docker buildx imagetools inspect ghcr.io/org/project:<sha>

# reference a locally built image by digest
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/org/project:<sha>
```

`create-deployment-info.sh` optionally accepts `IMAGE_DIGEST` to record the
digest in the deployment info JSON.

## Group breakdown

### Group 1: GitHub Actions & Multi-Cluster Selection

Owns: `workflow_dispatch`, cluster selection (checkboxes), job conditions,
end-of-run summary. See `.github/workflows/deploy.yml`.

**Definition of Done**

- [ ] `workflow_dispatch` with inputs for cluster selection (Cluster A/B, LUIS) is defined
- [ ] The "Build container" input (yes/no) works independently of cluster selection
- [ ] Each cluster has its own job with an `if:` condition that only runs when selected
- [ ] Jobs call the other groups' scripts with the agreed-upon parameters
- [ ] The workflow runs end-to-end at least once (even with placeholders from other groups)
- [ ] A failure in one cluster job doesn't block the other cluster jobs
- [ ] The end-of-run summary shows success/failure per cluster
- [ ] No secrets in plaintext in the workflow file; environments/secrets referenced correctly

### Group 2: Containers & Reproducible Environments

Owns: `Dockerfile`, image tags, GHCR push, starting the container, Docker
vs. Apptainer differences.

**Definition of Done**

- [ ] `Dockerfile` builds cleanly locally (`docker build .`)
- [ ] Image is tagged with the git SHA (`ghcr.io/org/project:<sha>`), not just `latest`
- [ ] Push to GHCR works from the Action
- [ ] Image can be referenced by digest, and reading it out is documented
- [ ] Container can be started locally, `hello.py` visibly runs through
- [ ] Short write-up: Docker vs. Apptainer (at least 3 points: daemon/root, image format, network/namespaces)
- [ ] Example command for GHCR → `.sif` (`apptainer pull docker://...`) documented
- [ ] GHCR package visibility/permissions clarified (private + which tokens may pull)

### Group 3: Transport & Remote Execution

Owns: `scripts/deploy.sh`, SSH, optionally `scripts/sync.sh`.

**Definition of Done**

- [ ] SSH connection to Cluster A and LUIS successfully tested (key-based)
- [ ] `deploy.sh` with a clearly documented signature: `./deploy.sh <cluster-name> <image-tag>`
- [ ] Script correctly distinguishes Docker (Cluster A/B) vs. Apptainer (LUIS) internally
- [ ] Pull + run on the target system demonstrably works
- [ ] Exit code is unambiguous (0 = success, ≠0 = failure)
- [ ] SSH access is restricted (`command=` restriction, no full shell access)
- [ ] Optional: `rsync` for source sync works and is cleanly separated from the Docker deploy logic
- [ ] Failure cases handled: cluster unreachable, image not found

### Group 4: Version Tracking & Verification

Owns: `scripts/create-deployment-info.sh`, `scripts/verify.sh`.

**Definition of Done**

- [ ] `create-deployment-info.sh` produces JSON with git commit, image tag/digest, timestamp
- [ ] `verify.sh` reads the actually running image tag for each cluster
- [ ] Expected (current git commit) vs. actual (per cluster) comparison is correct and readable
- [ ] Status output is unambiguous: ✓ up to date / OUTDATED / "unreachable" as a third state
- [ ] Script works even when only some clusters have been deployed
- [ ] Exit code reflects the overall status
- [ ] Short write-up: how "same code, same environment" is actually verified (tag vs. digest comparison)

## Integration

After group work: a shared phase where all four parts are integrated
against the real workflow (`deploy.yml`) - each group replaces its
placeholder with its own implementation, followed by an end-to-end run
across all clusters.

## Timeline

_TODO: add a timeline for the workshop day (preparation, group work,
integration, wrap-up)._
