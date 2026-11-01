#!/usr/bin/env python3
"""Column-level diff and structural check between two CSV exports.

It answers "which columns actually changed?" rather than "are these files
identical?", the question two exports of the same report usually raise.

Usage:
    csv_compare.py <a.csv> <b.csv> [--key COL[,COL...]] [--ignore COL[,COL...]]
    csv_compare.py --self-test

Without --key, rows are compared positionally. With --key, rows are matched on
the key columns, so added, removed and reordered rows are reported as such
rather than smearing across every subsequent row.

Reports, in order: field-count/parse anomalies, header differences, row
add/remove, then a per-column count of differing values with up to three
examples each. Exit 0 when the files agree on every compared column, 1 when
they differ, 2 on a usage or parse error.
"""

import argparse
import csv
import io
import sys
from collections import Counter

MAX_EXAMPLES = 3


def read_csv(path_or_handle, name):
    """Return (header, rows, anomalies). Rows are lists of strings."""
    if isinstance(path_or_handle, str):
        try:
            handle = open(path_or_handle, newline="", encoding="utf-8")
        except OSError as exc:
            print(f"error: cannot read {name}: {exc}", file=sys.stderr)
            sys.exit(2)
    else:
        handle = path_or_handle

    with handle:
        reader = csv.reader(handle)
        try:
            rows = list(reader)
        except csv.Error as exc:
            print(f"error: {name} is not parseable CSV: {exc}", file=sys.stderr)
            sys.exit(2)

    if not rows:
        return [], [], [f"{name} is empty"]

    header, body = rows[0], rows[1:]
    anomalies = [
        f"{name} line {i + 2}: {len(row)} fields, header has {len(header)}"
        for i, row in enumerate(body)
        if len(row) != len(header)
    ]
    return header, body, anomalies


def index_rows(header, rows, key_cols):
    """Map key tuple -> row. Duplicate keys are reported by the caller."""
    idx = {}
    dupes = Counter()
    positions = [header.index(c) for c in key_cols]
    for row in rows:
        key = tuple(row[p] if p < len(row) else "" for p in positions)
        if key in idx:
            dupes[key] += 1
        else:
            idx[key] = row
    return idx, dupes


def compare(path_a, path_b, key_cols=None, ignore=None, out=sys.stdout):
    ignore = set(ignore or [])
    header_a, rows_a, anom_a = read_csv(path_a, "A")
    header_b, rows_b, anom_b = read_csv(path_b, "B")

    differs = False

    for line in anom_a + anom_b:
        print(f"FIELD COUNT  {line}", file=out)
        differs = True

    if header_a != header_b:
        only_a = [c for c in header_a if c not in header_b]
        only_b = [c for c in header_b if c not in header_a]
        if only_a:
            print(f"HEADER       only in A: {', '.join(only_a)}", file=out)
        if only_b:
            print(f"HEADER       only in B: {', '.join(only_b)}", file=out)
        if not only_a and not only_b:
            print("HEADER       same columns, different order", file=out)
        differs = True

    shared = [c for c in header_a if c in header_b and c not in ignore]
    if not shared:
        print("no shared columns to compare", file=out)
        return 1 if differs else 0

    if key_cols:
        missing = [c for c in key_cols if c not in header_a or c not in header_b]
        if missing:
            print(f"error: key column(s) absent: {', '.join(missing)}", file=sys.stderr)
            sys.exit(2)
        idx_a, dupes_a = index_rows(header_a, rows_a, key_cols)
        idx_b, dupes_b = index_rows(header_b, rows_b, key_cols)
        for label, dupes in (("A", dupes_a), ("B", dupes_b)):
            for key, extra in dupes.items():
                print(f"DUPLICATE    {label} key {key}: {extra + 1} rows", file=out)
                differs = True
        only_a = [k for k in idx_a if k not in idx_b]
        only_b = [k for k in idx_b if k not in idx_a]
        for key in only_a[:MAX_EXAMPLES]:
            print(f"ROW          only in A: {key}", file=out)
        if len(only_a) > MAX_EXAMPLES:
            print(f"ROW          ... and {len(only_a) - MAX_EXAMPLES} more only in A", file=out)
        for key in only_b[:MAX_EXAMPLES]:
            print(f"ROW          only in B: {key}", file=out)
        if len(only_b) > MAX_EXAMPLES:
            print(f"ROW          ... and {len(only_b) - MAX_EXAMPLES} more only in B", file=out)
        if only_a or only_b:
            differs = True
        pairs = [(idx_a[k], idx_b[k]) for k in idx_a if k in idx_b]
    else:
        if len(rows_a) != len(rows_b):
            print(f"ROW COUNT    A={len(rows_a)} B={len(rows_b)}", file=out)
            differs = True
        pairs = list(zip(rows_a, rows_b))

    pos_a = {c: header_a.index(c) for c in shared}
    pos_b = {c: header_b.index(c) for c in shared}
    for col in shared:
        ia, ib = pos_a[col], pos_b[col]
        examples, count = [], 0
        for row_a, row_b in pairs:
            va = row_a[ia] if ia < len(row_a) else ""
            vb = row_b[ib] if ib < len(row_b) else ""
            if va != vb:
                count += 1
                if len(examples) < MAX_EXAMPLES:
                    examples.append(f"{va!r} != {vb!r}")
        if count:
            differs = True
            shown = "; ".join(examples)
            more = f" (+{count - len(examples)} more)" if count > len(examples) else ""
            print(f"COLUMN       {col}: {count}/{len(pairs)} differ — {shown}{more}", file=out)

    if not differs:
        print(f"identical on {len(shared)} shared columns across {len(pairs)} rows", file=out)
    return 1 if differs else 0


def self_test():
    def run(a, b, **kwargs):
        buf = io.StringIO()
        rc = compare(io.StringIO(a), io.StringIO(b), out=buf, **kwargs)
        return rc, buf.getvalue()

    base = "zone,peak,occupancy\nz1,10,0.5\nz2,20,0.6\n"

    rc, out = run(base, base)
    assert rc == 0, "identical files must exit 0"
    assert "identical on 3 shared columns" in out, out

    # A single differing column is named, and untouched columns are not.
    rc, out = run(base, "zone,peak,occupancy\nz1,10,0.5\nz2,99,0.6\n")
    assert rc == 1
    assert "COLUMN       peak: 1/2 differ" in out, out
    assert "COLUMN       occupancy" not in out, out

    # Header differences are reported in both directions.
    rc, out = run(base, "zone,peak\nz1,10\nz2,20\n")
    assert rc == 1
    assert "only in A: occupancy" in out, out

    # Ragged rows are caught before value comparison.
    rc, out = run(base, "zone,peak,occupancy\nz1,10\nz2,20,0.6\n")
    assert rc == 1
    assert "FIELD COUNT  B line 2: 2 fields" in out, out

    # Keyed matching reports add/remove instead of smearing.
    rc, out = run(base, "zone,peak,occupancy\nz2,20,0.6\nz3,30,0.7\n", key_cols=["zone"])
    assert rc == 1
    assert "only in A: ('z1',)" in out, out
    assert "only in B: ('z3',)" in out, out
    assert "COLUMN       peak" not in out, out

    # Keyed matching is order-insensitive.
    rc, out = run(base, "zone,peak,occupancy\nz2,20,0.6\nz1,10,0.5\n", key_cols=["zone"])
    assert rc == 0, out

    # Positional matching flags the same reorder as a difference.
    rc, out = run(base, "zone,peak,occupancy\nz2,20,0.6\nz1,10,0.5\n")
    assert rc == 1, out

    # Duplicate keys are surfaced.
    rc, out = run(base, "zone,peak,occupancy\nz1,10,0.5\nz1,10,0.5\n", key_cols=["zone"])
    assert "DUPLICATE    B key ('z1',): 2 rows" in out, out

    # --ignore removes a column from the comparison.
    rc, out = run(base, "zone,peak,occupancy\nz1,10,0.9\nz2,20,0.6\n", ignore=["occupancy"])
    assert rc == 0, out

    print("csv_compare self-test: PASS")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a", nargs="?", help="first CSV")
    parser.add_argument("b", nargs="?", help="second CSV")
    parser.add_argument("--key", help="comma-separated key columns for row matching")
    parser.add_argument("--ignore", help="comma-separated columns to skip")
    parser.add_argument("--self-test", action="store_true", help="run offline checks and exit")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.a or not args.b:
        parser.error("two CSV paths are required (or --self-test)")

    return compare(
        args.a,
        args.b,
        key_cols=args.key.split(",") if args.key else None,
        ignore=args.ignore.split(",") if args.ignore else None,
    )


if __name__ == "__main__":
    sys.exit(main())
