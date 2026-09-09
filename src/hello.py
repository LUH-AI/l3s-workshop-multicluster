import datetime
import os
import platform
import socket


def read_version() -> str:
    path = os.path.join(os.path.dirname(__file__), "..", "version.txt")
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return "unknown"


def main() -> None:
    print("=== multicluster-workshop: hello ===")
    print(f"time:      {datetime.datetime.now(datetime.timezone.utc).isoformat()}")
    print(f"host:      {socket.gethostname()}")
    print(f"python:    {platform.python_version()}")
    print(f"version:   {read_version()}")
    print(f"git_sha:   {os.environ.get('GIT_SHA', 'unknown')}")


if __name__ == "__main__":
    main()
