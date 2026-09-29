#!/usr/bin/env bash
# Counts the words of a book using both clusters, from this laptop.
#
#   laptop ──► gateway (A/node1) ──► slurm-agent (B) ──► mapper jobs (node3, node4)
#   laptop ◄── gateway ◄── reducer (A/node2) ◄── results
#
# Downloads "Pride and Prejudice" from Project Gutenberg unless you give a file,
# sends it to the gateway, shows the SLURM queue while the chunks run, and
# prints the top words and which node counted each chunk.
# Run ./wordcount.sh --help for the options.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "/..." arguments to Windows paths

BOOK_URL=https://www.gutenberg.org/cache/epub/1342/pg1342.txt
BOOK_FILE=data/pride-and-prejudice.txt
CLUSTER_A=cluster-a
CONTROLLER=slurmctld
LOCAL_PORT=18080
CHUNKS=8
TOP=10
FILE=

usage() {
    cat <<EOF
Usage: $0 [options] [FILE]

Counts the words of FILE (default: Pride and Prejudice, downloaded once into
$BOOK_FILE) across both clusters.

Options:
  --chunks N    split the text into N chunks = N SLURM tasks (default: $CHUNKS)
  --top N       show the N most common words (default: $TOP)
  --port N      local port for the connection to the gateway (default: $LOCAL_PORT)
  -h, --help    show this help

Examples:
  $0
  $0 --chunks 4 --top 20
  $0 my-book.txt
EOF
}

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need_number() { [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || die "$1 needs a number"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --chunks)  need_number "$@"; CHUNKS=$2; shift 2 ;;
        --top)     need_number "$@"; TOP=$2; shift 2 ;;
        --port)    need_number "$@"; LOCAL_PORT=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "unknown option '$1' (see --help)" ;;
        *)         FILE=$1; shift ;;
    esac
done
(( CHUNKS <= 100 )) || die "--chunks must be 1-100"

cd "$(dirname "$0")"

# The Windows "python3" is often only a Microsoft Store placeholder, so pick the
# first Python that actually runs.
PY=
for candidate in python3 python; do
    if "$candidate" -c 'import sys' > /dev/null 2>&1; then PY=$candidate; break; fi
done
[[ -n $PY ]] || die "Python was not found (needed to read the JSON answers)"

# Reads one field from a JSON document on stdin.
json_field() { "$PY" -c "import json, sys; print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }

api() { curl -sS --noproxy '*' -m 60 "$@"; }

if [[ -z $FILE ]]; then
    FILE=$BOOK_FILE
    if [[ ! -s $FILE ]]; then
        step "Downloading Pride and Prejudice from Project Gutenberg"
        mkdir -p "$(dirname "$FILE")"
        curl -fsSL --noproxy '*' -o "$FILE" "$BOOK_URL" || die "download failed: $BOOK_URL"
    fi
fi
[[ -s $FILE ]] || die "no such file: $FILE"
echo "Text: $FILE ($(wc -c < "$FILE" | tr -d ' ') bytes)"

step "Connecting to the gateway (kubectl port-forward to localhost:$LOCAL_PORT)"
# On Windows the cluster's NodePort isn't reachable from the laptop, so tunnel.
kubectl --context "$CLUSTER_A" port-forward svc/gateway "$LOCAL_PORT:8080" > /dev/null 2>&1 &
FORWARD_PID=$!
trap 'kill $FORWARD_PID 2> /dev/null || true' EXIT
GATEWAY=http://127.0.0.1:$LOCAL_PORT
for _ in $(seq 1 20); do
    api -f "$GATEWAY/health" > /dev/null 2>&1 && break
    sleep 0.5
done
api -f "$GATEWAY/health" > /dev/null 2>&1 \
    || die "cannot reach the gateway. Is it deployed? ./deploy/deploy.sh"
echo "Gateway is up"

step "Sending the text in $CHUNKS chunks"
started=$SECONDS
submitted=$(api -X POST -H 'Content-Type: text/plain' --data-binary "@$FILE" "$GATEWAY/jobs?chunks=$CHUNKS")
job_id=$(json_field job_id <<<"$submitted" 2>/dev/null) \
    || die "the gateway refused the job: $submitted
If it says 'cannot reach', run ./deploy/connect.sh"
gateway_node=$(json_field gateway_node <<<"$submitted")
echo "Job $job_id accepted by the gateway on $gateway_node"

step "Waiting for the SLURM tasks on cluster B (queue: task, state, node)"
while :; do
    answer=$(api "$GATEWAY/jobs/$job_id?top=$TOP")
    state=$(json_field state <<<"$answer")
    done_chunks=$(json_field done <<<"$answer")
    queue=$(docker exec "$CONTROLLER" squeue -h -o '%i:%T:%N' 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    printf '  %3ss  %s/%s chunks done   %s\n' "$(( SECONDS - started ))" "$done_chunks" "$CHUNKS" "${queue:-(queue empty)}"
    [[ $state == running ]] || break
    sleep 2
done
[[ $state == done ]] || die "job $state: $(json_field error <<<"$answer")"

step "Result (took $(( SECONDS - started ))s)"
"$PY" - "$answer" "$gateway_node" <<'EOF'
import json, sys
r, gateway_node = json.loads(sys.argv[1]), sys.argv[2]
print(f"{r['total_words']:,} words, {r['unique_words']:,} different words\n")
print(f"Top {len(r['top'])} words:")
for rank, (word, count) in enumerate(r["top"], 1):
    print(f"  {rank:>3}. {word:<12} {count:>7,}")
print("\nChunks (counted by the mapper on cluster B):")
for c in r["per_chunk"]:
    print(f"  {c['chunk']}  {c['node']:<6} {c['words']:>7,} words  {c['seconds']:.3f}s")
nodes = ", ".join(sorted({c["node"] for c in r["per_chunk"]}))
print(f"\nGateway on {gateway_node} (cluster A), mappers on {nodes} (cluster B),"
      f" reducer on {r['reducer_node']} (cluster A)")
EOF
