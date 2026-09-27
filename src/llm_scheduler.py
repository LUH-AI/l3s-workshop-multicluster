"""
LLM-assisted scheduling layer (optional).

Two modes:
  1. Script generator — given a cluster profile and an allocation,
     ask an LLM to produce a valid sbatch script (Approach A).
  2. Agentic scheduler — the LLM decides allocation, generates
     scripts, and submits them via tool calls (Approach B).

This module is a skeleton. It can work with any OpenAI-compatible API
(Ollama, vLLM, llama.cpp server, or a cloud provider).

Usage:
    # Script generation mode
    python src/llm_scheduler.py --generate --cluster luis --n-experiments 200

    # Agentic mode (stretch goal)
    python src/llm_scheduler.py --agent "run remaining benchmarks, prioritize shortest queue"

TODO for participants:
  - [ ] Connect to a real LLM endpoint (Ollama is easiest for local)
  - [ ] Add validation: parse generated scripts, check for required SBATCH directives
  - [ ] Add safety guardrails: never run arbitrary commands, only sbatch
  - [ ] Compare LLM-generated scripts against Jinja2 templates for correctness
  - [ ] Implement the agentic loop with tool definitions
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

# TODO: uncomment once you have an LLM endpoint
# import requests

CLUSTERS_FILE = Path(__file__).parent.parent / "config" / "clusters.json"


# ── LLM client ──────────────────────────────────────────────────────

# Default to a local Ollama instance. Participants can swap this for
# any OpenAI-compatible endpoint.
LLM_BASE_URL = "http://localhost:11434/v1"
LLM_MODEL = "llama3.1:8b"  # or "qwen2.5:7b", "codellama:13b", etc.


def llm_chat(messages: list[dict], tools: list[dict] | None = None) -> dict:
    """
    Send a chat completion request to an OpenAI-compatible API.

    Returns the response message dict.

    TODO: Replace this stub with a real HTTP call.
    """
    # ── STUB ────────────────────────────────────────────────────────
    # Uncomment and adapt once you have an endpoint:
    #
    # payload = {
    #     "model": LLM_MODEL,
    #     "messages": messages,
    #     "temperature": 0.2,  # low for deterministic script generation
    # }
    # if tools:
    #     payload["tools"] = tools
    #
    # resp = requests.post(
    #     f"{LLM_BASE_URL}/chat/completions",
    #     json=payload,
    #     timeout=120,
    # )
    # resp.raise_for_status()
    # return resp.json()["choices"][0]["message"]

    print("WARNING: LLM client is a stub. Connect to a real endpoint.")
    return {"role": "assistant", "content": "[stub response]"}


# ── Mode 1: LLM-based script generation (Approach A) ───────────────

SCRIPT_GEN_SYSTEM_PROMPT = """\
You are an HPC job script generator. Given a cluster profile (JSON)
and an experiment allocation, produce a valid SLURM batch script.

Rules:
- Output ONLY the script, no markdown fences, no explanation.
- Start with #!/bin/bash
- Include all #SBATCH directives matching the cluster profile.
- Load modules listed in the profile.
- Run the SMAC worker inside the container if env_manager is apptainer,
  or via pixi if env_manager is pixi.
- Set PYEXP_MAX_EXPERIMENTS to the number of allocated experiments.
- Create the log directory before running.
- Do not include any commands that modify the cluster (no apt, no pip
  install outside the container, no rm -rf).
"""


def generate_script_with_llm(
    cluster_name: str,
    cluster_profile: dict,
    n_experiments: int,
    n_workers: int = 1,
    image_tag: str = "latest",
) -> str:
    """
    Ask the LLM to generate a SLURM script for this cluster.

    Returns the generated script as a string.
    """
    user_prompt = f"""\
Cluster: {cluster_name}
Profile: {json.dumps(cluster_profile, indent=2)}
Experiments to run: {n_experiments}
Parallel workers: {n_workers}
Container image tag: {image_tag}
Registry: ghcr.io/your-org/project

Generate the sbatch script.
"""

    response = llm_chat([
        {"role": "system", "content": SCRIPT_GEN_SYSTEM_PROMPT},
        {"role": "user", "content": user_prompt},
    ])

    script = response.get("content", "")

    # Basic validation
    if not script.startswith("#!/bin/bash"):
        print("WARNING: generated script doesn't start with #!/bin/bash")
    if "#SBATCH" not in script:
        print("WARNING: generated script has no #SBATCH directives")

    # TODO: add more validation
    # - Check that the partition name matches the profile
    # - Check that module names are valid
    # - Run `sbatch --test-only` if available

    return script


# ── Mode 2: Agentic scheduler (Approach B) ──────────────────────────

# Tool definitions for the agent (OpenAI function-calling format).
AGENT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_experiment_state",
            "description": (
                "Query the PyExperimenter database. Returns counts of "
                "total, done, running, and pending experiments."
            ),
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_cluster_capacity",
            "description": (
                "Query one cluster's SLURM state via SSH. Returns idle "
                "node count, running jobs, pending jobs."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "cluster_name": {
                        "type": "string",
                        "description": "Name from clusters.json",
                    },
                },
                "required": ["cluster_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "submit_batch",
            "description": (
                "Generate a SLURM script for the given cluster and "
                "number of experiments, and submit it via sbatch."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "cluster_name": {"type": "string"},
                    "n_experiments": {"type": "integer"},
                    "n_workers": {"type": "integer"},
                },
                "required": ["cluster_name", "n_experiments"],
            },
        },
    },
]

AGENT_SYSTEM_PROMPT = """\
You are an HPC experiment scheduler. You manage a SMAC benchmark
campaign across multiple clusters. Your job:

1. Check the experiment grid state (how many runs are pending).
2. Check each cluster's capacity (idle nodes, queue depth).
3. Decide how to distribute pending experiments across clusters.
4. Submit batches to each cluster.

Prefer clusters with shorter queues. Don't exceed budget limits.
Don't submit to unreachable clusters. Explain your reasoning briefly
before each action.
"""


def handle_tool_call(name: str, arguments: dict) -> str:
    """
    Execute a tool call from the agent and return the result as a string.

    TODO for participants:
      - Wire these to the real implementations in cluster_state.py
        and allocator.py
      - Add safety checks (e.g. cap n_experiments, validate cluster_name)
    """
    if name == "get_experiment_state":
        # TODO: replace with real PyExperimenter query
        return json.dumps({
            "total": 600, "done": 50, "running": 20, "pending": 530
        })

    elif name == "get_cluster_capacity":
        cluster_name = arguments["cluster_name"]
        # TODO: replace with real cluster_state.get_cluster_status()
        return json.dumps({
            "cluster": cluster_name,
            "reachable": True,
            "idle_nodes": 3,
            "running_jobs": 5,
            "pending_jobs": 2,
        })

    elif name == "submit_batch":
        cluster_name = arguments["cluster_name"]
        n_experiments = arguments["n_experiments"]
        # TODO: replace with real allocator.submit_to_cluster()
        return json.dumps({
            "cluster": cluster_name,
            "submitted": n_experiments,
            "job_id": "STUB-12345",
        })

    else:
        return json.dumps({"error": f"unknown tool: {name}"})


def run_agent(user_request: str, max_steps: int = 10) -> None:
    """
    Run the agentic scheduling loop.

    The agent iterates: reason → tool call → observe → reason → ...
    until it decides it's done or hits max_steps.

    TODO for participants:
      - Connect llm_chat to a real model that supports tool calling
      - Parse tool_calls from the response and dispatch them
      - Add a confirmation step before actual submission
    """
    messages = [
        {"role": "system", "content": AGENT_SYSTEM_PROMPT},
        {"role": "user", "content": user_request},
    ]

    for step in range(max_steps):
        print(f"\n── Agent step {step + 1} ──")

        response = llm_chat(messages, tools=AGENT_TOOLS)

        # Print the agent's reasoning
        if response.get("content"):
            print(f"Agent: {response['content']}")

        # Check for tool calls
        tool_calls = response.get("tool_calls", [])
        if not tool_calls:
            print("Agent finished (no more tool calls).")
            break

        # Execute each tool call
        messages.append(response)
        for tc in tool_calls:
            fn_name = tc["function"]["name"]
            fn_args = json.loads(tc["function"]["arguments"])
            print(f"  → Calling {fn_name}({fn_args})")

            result = handle_tool_call(fn_name, fn_args)
            print(f"  ← {result}")

            messages.append({
                "role": "tool",
                "tool_call_id": tc["id"],
                "content": result,
            })
    else:
        print(f"Agent hit max steps ({max_steps}).")


# ── CLI ─────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="LLM-assisted scheduling for SMAC benchmarks."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--generate", action="store_true",
        help="Generate a SLURM script using the LLM.",
    )
    group.add_argument(
        "--agent", type=str, metavar="REQUEST",
        help="Run the agentic scheduler with a natural-language request.",
    )
    parser.add_argument("--cluster", type=str, default="cluster-a")
    parser.add_argument("--n-experiments", type=int, default=100)
    parser.add_argument("--image-tag", type=str, default="latest")
    args = parser.parse_args()

    if args.generate:
        clusters = json.loads(CLUSTERS_FILE.read_text())
        profile = clusters.get(args.cluster, {})
        script = generate_script_with_llm(
            args.cluster, profile, args.n_experiments,
            image_tag=args.image_tag,
        )
        print(script)

    elif args.agent:
        run_agent(args.agent)


if __name__ == "__main__":
    main()
