"""mapper: counts the words in one chunk of text (the "map" step of word count).

Runs on cluster B as one SLURM array task per chunk, inside Apptainer:

    python mapper.py CHUNK_FILE RESULT_FILE

Writes RESULT_FILE as JSON:
    {"chunk": "chunk-000.txt", "node": "node3", "words": 1234, "seconds": 0.01,
     "counts": {"the": 80, ...}}

Words are lowercase letters with inner apostrophes ("don't"); everything else
separates words.
"""

import json
import os
import re
import socket
import sys
import time
from collections import Counter

WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")


def count_words(text):
    return Counter(WORD.findall(text.lower()))


def main(argv):
    if len(argv) != 3:
        print("usage: python mapper.py CHUNK_FILE RESULT_FILE", file=sys.stderr)
        return 2
    chunk_file, result_file = argv[1], argv[2]

    start = time.time()
    with open(chunk_file, encoding="utf-8") as f:
        counts = count_words(f.read())
    result = {
        "chunk": os.path.basename(chunk_file),
        "node": os.environ.get("NODE_NAME") or socket.gethostname(),
        "words": sum(counts.values()),
        "seconds": round(time.time() - start, 3),
        "counts": counts,
    }

    # Write to a temp file first so nobody reads a half-written result.
    with open(result_file + ".tmp", "w", encoding="utf-8") as f:
        json.dump(result, f)
    os.replace(result_file + ".tmp", result_file)
    print(f"{result['chunk']}: {result['words']} words on {result['node']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
