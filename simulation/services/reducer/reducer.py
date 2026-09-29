"""reducer: merges the per-chunk word counts (cluster A, node2).

    GET /jobs/<id>?top=10
        while running -> {"job_id", "state": "running", "chunks", "done", "per_chunk"}
        when done     -> also "total_words", "unique_words", "top": [["the", 4321], ...]
    GET /health

Asks the slurm-agent on cluster B for the job's results, adds the counts of all
chunks together and keeps finished jobs in memory. "per_chunk" shows which
node counted each chunk and how long it took.

Environment:
    PORT             8080
    SLURM_AGENT_URL  http://slurm-agent:8090
"""

import json
import os
import socket
import sys
import urllib.error
import urllib.request
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8080"))
SLURM_AGENT_URL = os.environ.get("SLURM_AGENT_URL", "http://slurm-agent:8090").rstrip("/")
NODE = os.environ.get("NODE_NAME") or socket.gethostname()

finished = {}  # job_id -> (Counter of all words, per_chunk list)

# Ignore proxy settings: all our calls are to services inside the lab.
_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(method, url, body=None):
    """Sends JSON to another service; returns (status, JSON answer)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with _opener.open(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except ValueError:
            return e.code, {"error": f"{url} answered {e.code}"}
    except OSError as e:
        return 502, {"error": f"cannot reach {url}: {e}"}


def per_chunk(results):
    return [{k: r[k] for k in ("chunk", "node", "words", "seconds")} for r in results]


def job_answer(job_id, top):
    """Returns (status, answer) for a job: progress, or the merged word counts."""
    if job_id not in finished:
        code, job = call("GET", f"{SLURM_AGENT_URL}/jobs/{job_id}")
        if code != 200:
            return code, job
        if job["state"] != "done":
            answer = {k: job.get(k) for k in ("job_id", "state", "chunks", "done", "error")}
            answer["per_chunk"] = per_chunk(job["results"])
            return 200, answer
        totals = Counter()
        for result in job["results"]:
            totals.update(result["counts"])
        finished[job_id] = (totals, per_chunk(job["results"]))

    totals, chunks = finished[job_id]
    return 200, {
        "job_id": job_id,
        "state": "done",
        "chunks": len(chunks),
        "done": len(chunks),
        "total_words": sum(totals.values()),
        "unique_words": len(totals),
        "top": totals.most_common(top),
        "per_chunk": chunks,
        "reducer_node": NODE,
    }


class Handler(BaseHTTPRequestHandler):
    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path.rstrip("/")
        if path == "/health":
            return self.send_json(200, {"service": "reducer", "status": "ok", "node": NODE})
        if path.startswith("/jobs/"):
            try:
                top = int(parse_qs(url.query).get("top", ["10"])[0])
            except ValueError:
                return self.send_json(400, {"error": "top must be a number"})
            return self.send_json(*job_answer(path[len("/jobs/"):], top))
        self.send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[reducer] {fmt % args}\n")


if __name__ == "__main__":
    print(f"[reducer] listening on :{PORT}, agent {SLURM_AGENT_URL}", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
