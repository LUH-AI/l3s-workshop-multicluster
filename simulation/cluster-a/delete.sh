#!/usr/bin/env bash
# Deletes cluster A: the minikube profile, its node containers and kubectl context.
#
#   ./cluster-a/delete.sh [--name NAME]
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash: don't rewrite "/..." arguments to Windows paths

NAME=cluster-a

usage() {
    cat <<EOF
Usage: $0 [--name NAME]

Deletes cluster A completely.

Options:
  --name NAME   minikube profile to delete (default: $NAME)
  -h, --help    show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)    [[ -n ${2:-} ]] || { echo "--name needs a value" >&2; exit 1; }; NAME=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "unknown option '$1' (see --help)" >&2; exit 1 ;;
    esac
done

[[ $NAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "--name must be lowercase letters, digits and '-'" >&2; exit 1; }

# Retry: on Windows a file in the profile folder can be briefly locked (e.g. by
# antivirus), which makes minikube delete fail.
for attempt in 1 2 3; do
    minikube delete -p "$NAME" && exit 0
    (( attempt < 3 )) && { echo "minikube delete failed, retrying in 5s" >&2; sleep 5; }
done
echo "ERROR: could not delete '$NAME'; run 'minikube delete -p $NAME' and try again" >&2
exit 1
