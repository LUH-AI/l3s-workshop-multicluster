# Contributing

Guidelines for working on this repository during the workshop session
and for asynchronous contributions afterwards.

---

## Pre-workshop checklist

Complete this **before** arriving at the session. Everything else in the
workshop depends on it, and it takes 30–45 minutes the first time
through.

| Step | How to verify |
|---|---|
| Fork the repo and clone your fork | `git remote -v` shows your fork under `origin` |
| Generate the SSH key pair | `ls ~/workshop-keys/runner_key` exists |
| Create a classic PAT (`write:packages`) and store it as the `GHCR_TOKEN` repo secret | Settings → Secrets → `GHCR_TOKEN` shows "Updated …" |
| Store the private key as the `SSH_PRIVATE_KEY` repo secret | Settings → Secrets → `SSH_PRIVATE_KEY` shows "Updated …" |
| Register and start the self-hosted runner | Settings → Actions → Runners shows "Idle" |
| Build the Cluster A simulator | `docker ps` shows a running `cluster-a` container |
| Run the smoke test workflow | `.github/workflows/test_runner.yml` passes (green check) |
| Run preflight | `./scripts/preflight.sh` reports Cluster A as reachable |
| Deploy and verify once | `./scripts/deploy.sh cluster-a dummy` then `./scripts/verify.sh dummy cluster-a` both succeed |

If any row fails, fix it before moving on — the README's Individual
Setup section has the full walkthrough. Bring issues you couldn't
resolve to the session's kick-off so the group can unblock them quickly.

---

## How the fork model works

There is no shared write access to the upstream repo during the session.
Every participant works on their own fork, pushes to their own GHCR
namespace (`ghcr.io/<your-username>/project`), and runs their own
self-hosted runner. This means:

- You can push to `main` freely on your fork without affecting anyone
  else.
- Your `config/clusters.json` has your own usernames and paths — it
  will always differ from others'.
- Upstream gets changes back via pull requests after the session, not
  during it.

---

## Branch conventions

| Branch | Purpose | Who pushes |
|---|---|---|
| `main` | Stable, working pipeline — Cluster A deploys from here | Anyone, after local testing passes |
| `wp1/<topic>` | WP1 work (e.g. `wp1/reverse-tunnel`, `wp1/wal-setup`) | WP1 group |
| `wp2/<topic>` | WP2 work (e.g. `wp2/ansible-comparison`) | WP2 group |
| `wp3/<topic>` | WP3 work (e.g. `wp3/pyexperimenter-worker`, `wp3/allocator-stub`) | WP3 group |

During the session, working directly on `main` in your fork is fine for
small, tested changes. Use a topic branch when you want to keep
something experimental without risking the `deploy.sh`/`verify.sh` path
that others might be depending on as a baseline.

---

## Coordination between work packages

The three WPs have deliberate interfaces between them. Agree on these
at kick-off and stick to them:

```
WP1 (pipeline)
  │
  ├── config/clusters.json schema ──────► WP3 Component 1 reads it
  │
  └── Central DB connection (§7) ───────► WP3 Component 2 writes to it
        ▲                                    │
        │ fallback: local-sync default       │
        └────────────────────────────────────┘

WP2 (alternatives)
  │
  └── doc/ansible-hpc-automation.md ────► WP3 Component 1 can use it
```

**Key rule:** WP3 Component 2 must not block on WP1's reverse tunnel.
Build against the local-sync default (workers write locally, results are
pulled back afterwards). If the tunnel is ready in time, swap it in as
an upgrade.

### Integration checkpoint (around the halfway mark)

At roughly 1:30–1:45 into the session, regroup briefly and confirm:

- WP1: can `deploy.sh` and `verify.sh` still run against Cluster A?
  Has the `clusters.json` schema changed in a way WP3 needs to know?
- WP2: any findings that change WP1's approach? Surface them now.
- WP3: is Component 1 deploying to at least one real cluster? Is
  Component 2's worker loop running locally? Does Component 3 have a
  stubbed predictor interface agreed?

If something is blocked, this is the time to swap help across WPs
rather than discovering it during the demo.

---

## What to change vs. what not to touch

### Safe to change in your fork

- `config/clusters.json` — add your own cluster entries freely
- `src/hello.py` — replace with your PyExperimenter worker or workload
- `requirements.txt` — add dependencies your code needs
- `Dockerfile` — extend as needed (keep `python:3.10-slim` as the base)
- `doc/` — improve, correct, or extend documentation
- `scripts/*.sh` — fix bugs, add error handling, extend functionality

### Be careful with

- `.github/workflows/*.yml` — changes here affect CI for your entire
  fork. Test locally first (`./scripts/deploy.sh`, `./scripts/verify.sh`)
  before relying on a workflow run to catch problems.
- `cluster-config/local-docker.sh` — rebuilding the simulator resets
  its host keys (the script handles `known_hosts` cleanup, but be aware).

### Do not change

- The `clusters.json` field names that `deploy.sh`/`verify.sh`/`sync.sh`
  read (`host`, `port`, `user`, `key`, `type`, `sync_path`) — other
  people's scripts depend on that schema. Add new fields if you need
  them; don't rename existing ones.

---

## Commit and PR conventions

### Commit messages

Prefix with the work package or scope:

```
wp1: add reverse-tunnel systemd unit
wp3: wire PyExperimenter worker into container entrypoint
docs: fix LUIS storage path in clusters.md
scripts: handle missing jq gracefully in preflight.sh
ci: add KISSKI to deploy matrix
```

Keep the first line under 72 characters. A body paragraph is welcome for
anything non-obvious.

### Pull requests back to upstream (after the session)

Once your fork has working, tested changes worth sharing:

1. Open a PR from your fork's branch to upstream `main`.
2. Title it with the WP and a short summary:
   `WP3: PyExperimenter worker loop with local-sync fallback`.
3. In the description, state what you tested it against (Cluster A only?
   LUIS? KISSKI?) and any known limitations.
4. If the PR touches `clusters.json`, make sure you haven't committed
   your personal usernames/paths — use `<your-username>` placeholders
   or add a `.gitignore` entry for a local override file.

---

## Testing before pushing

The repo has no automated test suite (yet). Before pushing to `main` or
opening a PR, manually verify:

```bash
# 1. Does the pipeline still work end-to-end against Cluster A?
./scripts/preflight.sh
./scripts/deploy.sh cluster-a dummy
./scripts/verify.sh dummy cluster-a

# 2. If you changed the Dockerfile, does it still build?
docker build -t test-build .

# 3. If you changed a workflow, does the script it calls still work
#    when run locally? (Workflows are hard to test in isolation —
#    test the underlying script instead.)
./scripts/sync.sh cluster-a
```

If you added a real cluster, also test `deploy.sh` and `verify.sh`
against it — a green Cluster A run doesn't guarantee the same script
works against an Apptainer target.

---

## Adding a new cluster

This is a config-only operation — no script changes needed:

1. Get SSH access working: `ssh <user>@<host>` succeeds with the
   workshop key.
2. Add an entry to `config/clusters.json` using the templates in
   `doc/clusters.md`.
3. Run `./scripts/preflight.sh` — your new cluster should show as
   reachable.
4. Run `./scripts/deploy.sh <cluster-name> dummy` — confirm it pulls
   successfully.
5. Run `./scripts/verify.sh dummy <cluster-name>` — confirm it reports
   a match.
6. For SLURM clusters: real workloads must go through `sbatch`, not the
   login node. `deploy.sh <cluster> <tag> --run` is only a smoke test.

---

## Sensitive information

- **Never commit private keys, PATs, or passwords.** These belong in
  GitHub Actions secrets or your local `ssh-agent`, not in files.
- **Never commit `clusters.json` with real usernames.** Use
  `<your-username>` placeholders in any version you push upstream.
  Your fork's copy will naturally have your real username — that's fine
  as long as it stays in your fork.
- The `.gitignore` already covers common patterns, but double-check
  `git diff --cached` before committing if you've been editing config
  files.

---

## Getting help during the session

- **Pipeline not working:** run `./scripts/preflight.sh` first — it
  checks SSH reachability and agent status before anything else.
- **Cluster-specific issue:** check `doc/clusters.md` for known
  pitfalls and the README's pitfalls table.
- **Blocked on another WP's output:** use the local-sync default and
  move on. Flag it at the next sync checkpoint.
- **Something not covered here:** ask in the session's shared channel.
  If you solve it, add the fix to the relevant doc file — that's a
  valid contribution too.
