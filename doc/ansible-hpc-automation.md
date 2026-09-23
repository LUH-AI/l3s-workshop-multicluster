# HPC Automation with Ansible and Fabric

Reference guide for automated deployment to LUIS, KISSKI, and PC2 using
Ansible (static environment setup) and Fabric (dynamic job submission).

---

## Architecture

The two tools cover different parts of the workflow:

| Tool | Role | When to use |
|---|---|---|
| **Ansible** | Static baseline | Directory creation, container pulls — run once per cluster, or after a reset |
| **Fabric** | Dynamic actions | SLURM job submission, live log retrieval — run per experiment |

---

## 1. Local SSH configuration

Before running either tool, configure SSH multiplexing on your local machine.
This lets you authenticate once (including 2FA where required) and reuse the
connection for all subsequent Ansible and Fabric calls.

```
# ~/.ssh/config

Host *
    ControlMaster auto
    ControlPath ~/.ssh/ansible-%r@%h:%p
    ControlPersist 30m

Host luis
    HostName login.cluster.uni-hannover.de

Host kisski
    HostName glogin9.hlrn.de
    IdentityFile ~/.ssh/id_academiccloud

Host pc2
    HostName fe.noctua2.pc2.uni-paderborn.de
```

**Workflow:** run `ssh luis` (or `kisski`, `pc2`) once in a terminal, complete
any 2FA prompt, and leave the connection open. Ansible and Fabric will reuse
the multiplexed socket automatically for up to 30 minutes, bypassing further
2FA prompts.

---

## 2. Ansible: environment setup playbook

`setup_hpc.yml` creates the working directories and pulls the Apptainer
container image on the login node. Run it once before submitting jobs.

```yaml
# setup_hpc.yml
---
- name: Initialize cluster environments
  hosts: all
  gather_facts: false
  vars:
    username: "your_username"
    project_acronym: "lsdfa"       # PC2 only
    container_url: "docker://ghcr.io/<your-org>/project:latest"

  tasks:
    - name: Resolve base directory per cluster
      set_fact:
        base_dir: >-
          {{ '/bigwork/' + username           if inventory_hostname == 'luis'   else
             '/scratch/usr/' + username       if inventory_hostname == 'kisski' else
             '/scratch/hpc-prf-' + project_acronym + '/' + username }}

    - name: Create repo and scratch directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: '0755'
      loop:
        - "{{ base_dir }}/repo"
        - "{{ base_dir }}/scratch"

    - name: Pull Apptainer image onto login node
      ansible.builtin.command:
        cmd: "apptainer pull -F {{ base_dir }}/scratch/image.sif {{ container_url }}"
```

Run against all three clusters simultaneously:

```bash
ansible-playbook -i luis,kisski,pc2 setup_hpc.yml
```

Or target a single cluster:

```bash
ansible-playbook -i luis, setup_hpc.yml
```

> **Note:** `apptainer pull` is safe to run on the login node — it downloads
> and converts the image but does not execute any workload. The resulting
> `.sif` file lands in `scratch/` within your base directory.

---

## 3. Fabric: SLURM job launcher

`fabfile.py` generates a SLURM batch script on the fly and submits it via SSH.
No resource-intensive work touches the login node.

```python
# fabfile.py
from fabric import Connection, task

CLUSTERS = {
    "luis":   {"host": "luis",   "work_dir": "/bigwork/your_username/repo"},
    "kisski": {"host": "kisski", "work_dir": "/scratch/usr/your_username/repo"},
    "pc2":    {"host": "pc2",    "work_dir": "/scratch/hpc-prf-lsdfa/your_username/repo"},
}

@task
def run_benchmark(ctx, cluster_name):
    """Submit a SLURM job to the specified cluster."""
    if cluster_name not in CLUSTERS:
        print(f"Unknown cluster. Choose from: {list(CLUSTERS.keys())}")
        return

    cfg = CLUSTERS[cluster_name]
    c = Connection(cfg["host"])

    slurm_script = f"""#!/bin/bash
#SBATCH --job-name=hpc_benchmark
#SBATCH --output={cfg['work_dir']}/job_%j.log
#SBATCH --time=00:30:00

cd {cfg['work_dir']}
apptainer exec ../scratch/image.sif python3 benchmark.py
"""

    remote_script = f"{cfg['work_dir']}/run.sh"
    c.run(f"cat > {remote_script} << 'SBATCH_EOF'\n{slurm_script}\nSBATCH_EOF")
    result = c.run(f"sbatch {remote_script}", hide=True)
    print(f"[{cluster_name}] {result.stdout.strip()}")
```

Submit a job:

```bash
fab run-benchmark --cluster-name luis
fab run-benchmark --cluster-name kisski
```

---

## 4. Storage paths quick reference

| Cluster | Base path | Notes |
|---|---|---|
| LUIS | `/bigwork/<username>/` | Use instead of `~` — larger quota |
| KISSKI | `/scratch/usr/<username>/` | High-performance scratch |
| PC2 | `/scratch/hpc-prf-<acronym>/<username>/` | Project acronym required |

---

## 5. Relation to the workshop pipeline

These tools are **complementary** to the existing `deploy.sh` / `sync.sh`
scripts, not a replacement:

| Workshop script | Ansible/Fabric equivalent | When to prefer |
|---|---|---|
| `scripts/sync.sh` | `ansible-playbook setup_hpc.yml` | Ansible is better for first-time setup across multiple clusters at once |
| `scripts/deploy.sh` | `fab run-benchmark` | Fabric is better for repeated job submissions without re-running the full deploy |
| `config/clusters.json` | `CLUSTERS` dict in `fabfile.py` | Keep both in sync — single source of truth is still `clusters.json` |

For the workshop itself, `deploy.sh` and `sync.sh` are the primary tools.
Ansible and Fabric become useful when managing more than two or three clusters
regularly, or when you want to schedule setup steps independently from job
submission.
