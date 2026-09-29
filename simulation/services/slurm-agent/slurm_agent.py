"""slurm-agent: the only way into cluster B.

Runs on the slurmctld container. Takes text chunks over HTTP, runs one SLURM
array task per chunk (the mapper, inside Apptainer) and reports progress and
results.

    POST /jobs        {"chunks": ["text", ...]}
                      -> 201 {"job_id": "wc-1a2b3c4d", "chunks": 4, "slurm_job_id": "17"}
    GET  /jobs/<id>   -> {"job_id", "state": "running|done|failed", "chunks", "done",
                          "results": [mapper result, ...]}
    GET  /health

Files live in SHARED_DIR/jobs/<id>/: chunk-NNN.txt, result-NNN.json,
task-N.log, job.sbatch, meta.json.

Environment:
    PORT        8090
    SHARED_DIR  /shared
    EXECUTOR    slurm (default) or local. local runs mapper.py directly instead of
                SLURM + Apptainer, so the whole system can be tried on a laptop.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PORT", "8090"))
SHARED_DIR = Path(os.environ.get("SHARED_DIR", "/shared"))
EXECUTOR = os.environ.get("EXECUTOR", "slurm")
HERE = Path(__file__).resolve().parent
JOB_TEMPLATE = HERE / "wordcount.sbatch"
LOCAL_MAPPER = HERE.parent / "mapper" / "mapper.py"
JOB_ID = re.compile(r"^wc-[0-9a-f]{8}$")
MAX_BODY = 50 * 1024 * 1024


def job_dir(job_id):
    return SHARED_DIR / "jobs" / job_id


def submit(chunks):
    """Writes the chunks to the job folder and starts one task per chunk."""
    job_id = "wc-" + uuid.uuid4().hex[:8]
    folder = job_dir(job_id)
    folder.mkdir(parents=True)
    for i, text in enumerate(chunks):
        (folder / f"chunk-{i:03d}.txt").write_text(text, encoding="utf-8")
    meta = {"job_id": job_id, "chunks": len(chunks), "submitted": time.time()}

    if EXECUTOR == "local":
        threading.Thread(target=run_local, args=(folder, len(chunks)), daemon=True).start()
    else:
        script = JOB_TEMPLATE.read_text().replace("\r", "").replace("@JOB_DIR@", str(folder))
        (folder / "job.sbatch").write_text(script)
        out = subprocess.run(
            ["sbatch", "--parsable", f"--array=0-{len(chunks) - 1}", str(folder / "job.sbatch")],
            capture_output=True, text=True, check=True,
        )
        meta["slurm_job_id"] = out.stdout.strip().split(";")[0]

    (folder / "meta.json").write_text(json.dumps(meta))
    return meta


def run_local(folder, count):
    for i in range(count):
        subprocess.run([sys.executable, str(LOCAL_MAPPER),
                        str(folder / f"chunk-{i:03d}.txt"), str(folder / f"result-{i:03d}.json")],
                       env={**os.environ, "NODE_NAME": "local"}, check=False)


def status(job_id):
    """Returns the job's state and the results of the chunks that are done."""
    folder = job_dir(job_id)
    meta = json.loads((folder / "meta.json").read_text())

    # Ask SLURM first, then read results: a task that finishes in between is
    # then seen as done rather than as missing.
    still_queued = True
    if EXECUTOR != "local":
        out = subprocess.run(["squeue", "-h", "-j", meta["slurm_job_id"]],
                             capture_output=True, text=True)
        still_queued = bool(out.stdout.strip())

    results = [json.loads(p.read_text()) for p in sorted(folder.glob("result-*.json"))]
    answer = {"job_id": job_id, "chunks": meta["chunks"], "done": len(results),
              "slurm_job_id": meta.get("slurm_job_id"), "results": results}
    if len(results) == meta["chunks"]:
        answer["state"] = "done"
    elif still_queued:
        answer["state"] = "running"
    else:
        answer["state"] = "failed"
        answer["error"] = f"some tasks ended without a result; see {folder}/task-*.log"
    return answer


class Handler(BaseHTTPRequestHandler):
    def send_json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/health":
            return self.send_json(200, {"service": "slurm-agent", "status": "ok",
                                        "executor": EXECUTOR, "node": socket.gethostname()})
        if path.startswith("/jobs/"):
            job_id = path[len("/jobs/"):]
            if not JOB_ID.match(job_id) or not (job_dir(job_id) / "meta.json").exists():
                return self.send_json(404, {"error": f"no job {job_id}"})
            return self.send_json(200, status(job_id))
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/jobs":
            return self.send_json(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            return self.send_json(413, {"error": "request too large"})
        try:
            chunks = json.loads(self.rfile.read(length))["chunks"]
            assert isinstance(chunks, list) and chunks and all(isinstance(c, str) for c in chunks)
            assert len(chunks) <= 100
        except (ValueError, KeyError, TypeError, AssertionError):
            return self.send_json(400, {"error": 'body must be {"chunks": ["text", ...]} with 1-100 chunks'})
        try:
            self.send_json(201, submit(chunks))
        except subprocess.CalledProcessError as e:
            self.send_json(500, {"error": f"sbatch failed: {e.stderr.strip()}"})

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[slurm-agent] {fmt % args}\n")


if __name__ == "__main__":
    (SHARED_DIR / "jobs").mkdir(parents=True, exist_ok=True)
    print(f"[slurm-agent] listening on :{PORT} (executor={EXECUTOR}, shared={SHARED_DIR})",
          file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
