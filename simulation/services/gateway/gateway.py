"""gateway: the entry point of the word-count system (cluster A, node1).

    POST /jobs?chunks=4    body: the text to count (plain text)
                           -> 202 {"job_id", "chunks", "status_url", "gateway_node"}
    GET  /jobs/<id>?top=10 -> the reducer's answer (progress, then the word counts)
    GET  /health

Splits the text into chunks on line boundaries and hands them to the
slurm-agent on cluster B, which runs one SLURM task per chunk.

Environment:
    PORT             8080
    SLURM_AGENT_URL  http://slurm-agent:8090
    REDUCER_URL      http://reducer:8080
"""

import json
import os
import socket
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8080"))
SLURM_AGENT_URL = os.environ.get("SLURM_AGENT_URL", "http://slurm-agent:8090").rstrip("/")
REDUCER_URL = os.environ.get("REDUCER_URL", "http://reducer:8080").rstrip("/")
NODE = os.environ.get("NODE_NAME") or socket.gethostname()
MAX_BODY = 50 * 1024 * 1024

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


def split_text(text, count):
    """Splits text into at most `count` chunks of similar size, on line boundaries."""
    target = len(text) / count
    chunks, current, size = [], [], 0
    for line in text.splitlines(keepends=True):
        current.append(line)
        size += len(line)
        if size >= target and len(chunks) < count - 1:
            chunks.append("".join(current))
            current, size = [], 0
    chunks.append("".join(current))
    return [c for c in chunks if c.strip()]


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
            return self.send_json(200, {"service": "gateway", "status": "ok", "node": NODE})
        if path.startswith("/jobs/"):
            query = f"?{url.query}" if url.query else ""
            return self.send_json(*call("GET", f"{REDUCER_URL}{path}{query}"))
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        if url.path.rstrip("/") != "/jobs":
            return self.send_json(404, {"error": "not found"})
        try:
            count = int(parse_qs(url.query).get("chunks", ["4"])[0])
            assert 1 <= count <= 100
        except (ValueError, AssertionError):
            return self.send_json(400, {"error": "chunks must be 1-100"})
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            return self.send_json(413, {"error": "text too large (max 50 MB)"})
        text = self.rfile.read(length).decode("utf-8", errors="replace")
        chunks = split_text(text, count)
        if not chunks:
            return self.send_json(400, {"error": "send the text to count as the request body"})

        code, job = call("POST", f"{SLURM_AGENT_URL}/jobs", {"chunks": chunks})
        if code != 201:
            return self.send_json(code, job)
        self.send_json(202, {"job_id": job["job_id"], "chunks": len(chunks),
                             "status_url": f"/jobs/{job['job_id']}", "gateway_node": NODE})

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[gateway] {fmt % args}\n")


if __name__ == "__main__":
    print(f"[gateway] listening on :{PORT}, agent {SLURM_AGENT_URL}, reducer {REDUCER_URL}",
          file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
