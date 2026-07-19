#!/usr/bin/env python3
"""Validate benchmark result JSON against the current result contract."""

import argparse
import collections
import json
import sys
from pathlib import Path

from result_schema import DEFAULT_SCHEMA, load_schema, validate_document


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument(
        "--complete-set",
        action="store_true",
        help="require exactly one result for every configured matrix entity",
    )
    args = parser.parse_args(argv)

    try:
        schema, metrics = load_schema(args.schema)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"invalid schema {args.schema}: {exc}", file=sys.stderr)
        return 2

    failed = False
    entities = []
    for path in args.files:
        try:
            with path.open() as fh:
                document = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"{path}: invalid JSON: {exc}", file=sys.stderr)
            failed = True
            continue
        fs = document.get("fs") if isinstance(document, dict) else None
        layout = document.get("layout") if isinstance(document, dict) else None
        if isinstance(fs, str) and isinstance(layout, str):
            entities.append(f"{fs}/{layout}")
        for error in validate_document(document, schema, metrics):
            print(f"{path}: {error}", file=sys.stderr)
            failed = True

    if args.complete_set:
        configurations = schema.get("configurations")
        if not isinstance(configurations, dict):
            print("schema.configurations must be an object", file=sys.stderr)
            return 2
        counts = collections.Counter(entities)
        expected = set(configurations)
        missing = sorted(expected - set(counts))
        unexpected = sorted(set(counts) - expected)
        duplicates = sorted(entity for entity, count in counts.items() if count > 1)
        if missing:
            print(
                f"result set missing configurations: {', '.join(missing)}",
                file=sys.stderr,
            )
            failed = True
        if unexpected:
            print(
                f"result set has unknown configurations: {', '.join(unexpected)}",
                file=sys.stderr,
            )
            failed = True
        if duplicates:
            print(
                f"result set has duplicate configurations: {', '.join(duplicates)}",
                file=sys.stderr,
            )
            failed = True

    if failed:
        return 1
    suffix = " as a complete matrix" if args.complete_set else ""
    print(f"validated {len(args.files)} result file(s){suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
