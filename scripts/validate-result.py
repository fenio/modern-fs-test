#!/usr/bin/env python3
"""Validate benchmark result JSON against the current result contract."""

import argparse
import json
import sys
from pathlib import Path

from result_schema import DEFAULT_SCHEMA, load_schema, validate_document


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    args = parser.parse_args(argv)

    try:
        schema, metrics = load_schema(args.schema)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"invalid schema {args.schema}: {exc}", file=sys.stderr)
        return 2

    failed = False
    for path in args.files:
        try:
            with path.open() as fh:
                document = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"{path}: invalid JSON: {exc}", file=sys.stderr)
            failed = True
            continue
        for error in validate_document(document, schema, metrics):
            print(f"{path}: {error}", file=sys.stderr)
            failed = True

    if failed:
        return 1
    print(f"validated {len(args.files)} result file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
