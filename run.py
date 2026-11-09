#!/usr/bin/env python3
"""Run every saved query and print the results.

  python3 run.py                 all queries, against demo/demo.db
  python3 run.py 02              one query by number
  python3 run.py --db path.db    against another database in the same schema

SQLite has no SQRT without the math extension in older builds, so it is registered here.
"""
import argparse
import math
import sqlite3
from pathlib import Path

HERE = Path(__file__).resolve().parent

ap = argparse.ArgumentParser()
ap.add_argument("only", nargs="?", default="")
ap.add_argument("--db", default=str(HERE / "demo" / "demo.db"))
args = ap.parse_args()

db = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
db.create_function("SQRT", 1, lambda x: math.sqrt(x) if x is not None and x >= 0 else None)

for f in sorted((HERE / "queries").glob("[0-9][0-9]-*.sql")):
    if not f.name.startswith(args.only):
        continue
    sql = f.read_text()
    question = next(l[3:] for l in sql.splitlines() if l.startswith("-- Q"))
    cur = db.execute(sql)
    cols = [c[0] for c in cur.description]
    rows = cur.fetchall()
    widths = [max(len(str(c)), *(len(str(r[i])) for r in rows)) if rows else len(c)
              for i, c in enumerate(cols)]
    print(f"\n## {question}\n")
    print("  ".join(str(c).ljust(w) for c, w in zip(cols, widths)))
    for r in rows:
        print("  ".join(("" if v is None else str(v)).ljust(w) for v, w in zip(r, widths)))
