# WP2: Alternative Solutions

Positions the pipeline built in WP1 against established
deployment/automation tools, and makes the case for why a leaner, custom
solution fits this specific context better than adopting one of them
wholesale.

## Why this comparison matters

It would have been possible to build the whole pipeline on top of an
existing framework instead of bespoke `deploy.sh`/`verify.sh`/`sync.sh`
scripts. That wasn't done by default/oversight - the tradeoffs are worth
stating explicitly, both to justify the choice and because the comparison
tools remain genuinely useful for parts of the system (see
`doc/ansible-hpc-automation.md`, which already treats Ansible and Fabric
as **complementary** to the custom scripts, not replacements).

## Ansible

**What it is:** declarative, idempotent configuration management with a
large module library (file/directory state, package installs, templated
configs, etc.), driven by YAML playbooks against an inventory of hosts.

**Where it's a genuinely better fit than the custom scripts:** one-time or
infrequent environment setup across many hosts at once - exactly what
`doc/ansible-hpc-automation.md`'s `setup_hpc.yml` already does (directory
creation + image pull across LUIS/KISSKI/PC2 in one command,
`ansible-playbook -i luis,kisski,pc2 setup_hpc.yml`). Idempotency also
means re-running it to fix drift is safe by construction, which a
one-shot bash script doesn't give you for free.

**Cost:** a real learning curve (YAML playbook structure, module semantics,
inventory/variable precedence rules) relative to "read a 70-line bash
script." For a handful of clusters and infrequent setup, that overhead
isn't obviously worth paying for the whole pipeline - which is why it's
used for the static setup slice specifically, not for `deploy.sh`'s job.

## Fabric

**What it is:** a Python-based SSH automation library/CLI. Conceptually
the closest existing tool to what `deploy.sh` does by hand - both are
"run this command over SSH on a named set of hosts," just with Fabric
giving you a proper task/connection abstraction (`@task`, `Connection`)
instead of raw `ssh ... "$REMOTE_CMD"`.

**This is the sharpest comparison point** for the "when is a plain script
enough, when do you need a real tool" question: `deploy.sh` and Fabric's
`fab run-benchmark` in `doc/ansible-hpc-automation.md` do almost the same
job. The custom script wins on zero dependencies and full visibility into
every SSH call (relevant given the secrets-handling requirements in
`doc/wp1_proposed_solution.md` §5 - it's easier to audit "does this ever
touch disk" in 70 lines of bash than inside a library's connection
handling). Fabric wins once you need more than a handful of ad-hoc
commands: real Python control flow, structured error handling per host,
parallel execution across many hosts, and dynamic SLURM script generation
that's easier to template in Python than in bash heredocs.

## Why the custom, leaner solution for this context

The workshop's actual target environment - a couple of Docker simulators
plus a small number of Apptainer/HPC clusters, with a small number of
people who need to understand and modify the whole pipeline in a few
hours - is exactly the regime where generic frameworks cost more than
they return:

- **Fewer moving parts to explain.** `deploy.sh cluster-a <sha>` is
  readable top to bottom by anyone who knows bash and SSH; onboarding
  time matters when the pipeline itself is a teaching/demo artifact, not
  just infrastructure.
- **No framework-specific debugging layer.** Errors are "the SSH command
  that ran and what it printed," not "which Ansible module failed inside
  which callback."
- **Right-sized for the actual scale.** Ansible's and Fabric's real
  advantages (idempotent drift correction, large-fleet parallelism) matter
  more at cluster counts and change frequencies well beyond what this
  project touches (2 simulators + up to ~3 real HPC targets, set up once
  and iterated on by a small team).

This isn't an argument that Ansible/Fabric are worse tools in general -
`doc/ansible-hpc-automation.md` already adopts both where they *are* the
better fit (static setup, and potentially heavier job-submission needs).
It's specifically that the deploy/verify hot path (WP1) stays custom
because its scope is narrow enough that a framework's generality is pure
overhead there.

## Optional extensions (not built, noted for completeness)

- **Terraform** - would be the natural comparison point for
  *provisioning* (spinning up the Docker simulator hosts themselves, or
  cloud infrastructure) rather than deploying onto already-existing hosts,
  which is the problem this project actually has. Worth a paragraph if
  the writeup wants to address "why not Infrastructure-as-Code," but out
  of scope for the current pipeline.
- **Argo Workflows / Kubeflow** - relevant if the target ever becomes
  Kubernetes-based rather than bare Docker/Apptainer hosts + SLURM. Not
  applicable to the current architecture; worth naming only to
  pre-empt "why not just use K8s" as a question.
