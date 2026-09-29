"""Runs the whole word-count system on this machine, without the clusters.

Starts slurm-agent (EXECUTOR=local, so mapper.py runs directly instead of
SLURM + Apptainer), reducer and gateway as local processes, sends a text to the
gateway, waits for the answer and checks it against a direct count.

    python services/run_local.py                 # generated sample text
    python services/run_local.py book.txt 8      # your own text, 8 chunks
"""

import json
import os
import random
import subprocess
import sys
import tempfile
import time
import urllib.request
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "mapper"))
from mapper import count_words  # noqa: E402

AGENT, REDUCER, GATEWAY = 18090, 18081, 18080
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http(method, url, data=None):
    req = urllib.request.Request(url, data=data, method=method)
    with opener.open(req, timeout=30) as resp:
        return json.loads(resp.read())


def sample_text():
    words = ("the cluster runs a job on every node while the scheduler waits for "
             "free cpus and the gateway sends text to the agent so each mapper "
             "counts words in its own chunk and the reducer adds them up").split()
    rng = random.Random(42)
    return "\n".join(" ".join(rng.choice(words) for _ in range(12)) for _ in range(4000)) + "\n"


def wait_healthy(port):
    for _ in range(50):
        try:
            return http("GET", f"http://127.0.0.1:{port}/health")
        except OSError:
            time.sleep(0.2)
    raise SystemExit(f"service on port {port} did not start")


def main():
    text = Path(sys.argv[1]).read_text(encoding="utf-8") if len(sys.argv) > 1 else sample_text()
    chunks = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    shared = tempfile.mkdtemp(prefix="wordcount-")
    env = {**os.environ, "PYTHONUNBUFFERED": "1",
           "SLURM_AGENT_URL": f"http://127.0.0.1:{AGENT}",
           "REDUCER_URL": f"http://127.0.0.1:{REDUCER}"}
    procs = [
        subprocess.Popen([sys.executable, str(HERE / "slurm-agent" / "slurm_agent.py")],
                         env={**env, "PORT": str(AGENT), "EXECUTOR": "local", "SHARED_DIR": shared}),
        subprocess.Popen([sys.executable, str(HERE / "reducer" / "reducer.py")],
                         env={**env, "PORT": str(REDUCER)}),
        subprocess.Popen([sys.executable, str(HERE / "gateway" / "gateway.py")],
                         env={**env, "PORT": str(GATEWAY)}),
    ]
    try:
        for port in (AGENT, REDUCER, GATEWAY):
            wait_healthy(port)

        job = http("POST", f"http://127.0.0.1:{GATEWAY}/jobs?chunks={chunks}", text.encode())
        print(f"submitted {job['job_id']} with {job['chunks']} chunks")
        for _ in range(100):
            answer = http("GET", f"http://127.0.0.1:{GATEWAY}/jobs/{job['job_id']}?top=5")
            if answer["state"] != "running":
                break
            time.sleep(0.2)

        print(json.dumps(answer, indent=2))
        expected = count_words(text)
        # Compare counts, not order: words with equal counts may come in any order.
        ok = (answer["state"] == "done"
              and answer["total_words"] == sum(expected.values())
              and all(expected[word] == count for word, count in answer["top"])
              and [c for _, c in answer["top"]] == [c for _, c in expected.most_common(5)])
        print("\nOK: counts match a direct count" if ok else "\nFAILED: counts differ")
        return 0 if ok else 1
    finally:
        for p in procs:
            p.terminate()


if __name__ == "__main__":
    sys.exit(main())
