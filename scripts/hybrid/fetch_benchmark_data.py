"""Downloads the benchmark's images (never committed): the 209 memegen templates and the 225 sampled face photos.

    python fetch_benchmark_data.py --out DATA_DIR

Writes DATA_DIR/gallery/<id>.<ext> (memegen's blank templates, as bench.py's gallery.csv names them) and
DATA_DIR/queries/<file> (muxspace/facial_expressions), and copies the CSVs next to them in bench.py's layout.
Missing downloads are reported and skipped, as bench.py skips query files that don't exist.
"""
import argparse
import csv
import os
import shutil
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, "benchmark")
MEMEGEN = "https://api.memegen.link/images/{name}"
MUXSPACE = "https://raw.githubusercontent.com/muxspace/facial_expressions/master/images/{name}"


def get(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return True
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "mememe-benchmark/1"})
            with urllib.request.urlopen(req, timeout=60) as r, open(path + ".part", "wb") as f:
                shutil.copyfileobj(r, f)
            os.replace(path + ".part", path)
            return True
        except Exception as e:  # noqa: BLE001
            if attempt == 3:
                print(f"  failed: {url}: {e}", file=sys.stderr)
            time.sleep(1.5 * (attempt + 1))
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = args.out
    os.makedirs(os.path.join(out, "gallery"), exist_ok=True)
    os.makedirs(os.path.join(out, "queries"), exist_ok=True)
    for name in ["gallery.csv", "gallery_labels.txt", "queries_sample.csv"]:
        shutil.copy(os.path.join(BENCH, name), os.path.join(out, name))

    jobs = []
    with open(os.path.join(BENCH, "gallery.csv"), newline="") as f:
        for row in csv.DictReader(f):
            name = os.path.basename(row["file"])
            jobs.append((MEMEGEN.format(name=name), os.path.join(out, "gallery", name)))
    with open(os.path.join(BENCH, "queries_sample.csv"), newline="") as f:
        for row in csv.DictReader(f):
            jobs.append((MUXSPACE.format(name=row["image"]), os.path.join(out, "queries", row["image"])))
    with ThreadPoolExecutor(8) as pool:
        ok = list(pool.map(lambda j: get(*j), jobs))
    print(f"downloaded {sum(ok)} of {len(jobs)} images into {out}")
    if sum(ok) < 0.9 * len(jobs):
        raise SystemExit("too many benchmark images are missing")


if __name__ == "__main__":
    main()
