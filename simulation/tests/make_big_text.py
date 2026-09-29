"""Generates a large text for testing the word count (MapReduce) on both clusters.

    python tests/make_big_text.py                  # 5,000,000 words -> tests/big-text.txt
    python tests/make_big_text.py --words 1000000  # smaller

Writes two files:
    tests/big-text.txt           the text: made-up words, 12 per line
    tests/big-text.expected.txt  the correct answer (total, different words, top 20)

Words follow Zipf's law like real language: a few words are very common, most
are rare. The same --words and --seed always give the same file.

Keep it under the gateway's 50 MB upload limit (about 8 million words).
"""

import argparse
import random
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
SYLLABLES = ["ka", "lo", "mi", "ne", "ru", "ta", "vo", "se", "di", "po",
             "an", "el", "ir", "on", "us", "ba", "fe", "gi", "ho", "ju"]


def vocabulary(size, rng):
    """Returns `size` different made-up words of 1-4 syllables."""
    words = set()
    while len(words) < size:
        words.add("".join(rng.choice(SYLLABLES) for _ in range(rng.randint(1, 4))))
    return sorted(words)


def main():
    parser = argparse.ArgumentParser(description="Generate a large text for the word-count test.")
    parser.add_argument("--words", type=int, default=5_000_000, help="number of words (default 5,000,000)")
    parser.add_argument("--vocabulary", type=int, default=20_000, help="different words to pick from")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out", default=str(HERE / "big-text.txt"))
    args = parser.parse_args()

    rng = random.Random(args.seed)
    vocab = vocabulary(args.vocabulary, rng)
    rng.shuffle(vocab)                                   # rank 1 = most common
    weights = [1 / rank for rank in range(1, len(vocab) + 1)]
    text_words = rng.choices(vocab, weights=weights, k=args.words)

    out = Path(args.out)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        for i in range(0, len(text_words), 12):
            f.write(" ".join(text_words[i:i + 12]) + "\n")

    counts = Counter(text_words)
    expected = out.with_name(out.stem + ".expected.txt")
    with open(expected, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"Expected word count of {out.name} (--words {args.words} --seed {args.seed})\n\n")
        f.write(f"{sum(counts.values()):,} words, {len(counts):,} different words\n\n")
        f.write("Top 20 words:\n")
        for rank, (word, count) in enumerate(counts.most_common(20), 1):
            f.write(f"  {rank:>3}. {word:<12} {count:>9,}\n")

    size_mb = out.stat().st_size / 1024 / 1024
    print(f"Wrote {out} ({args.words:,} words, {size_mb:.1f} MB)")
    print(f"Wrote {expected}")


if __name__ == "__main__":
    main()
