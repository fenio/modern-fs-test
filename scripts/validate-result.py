#!/usr/bin/env python3
"""Validate benchmark result JSON against the current result contract."""

import argparse
import json
import math
import sys
from pathlib import Path


DEFAULT_SCHEMA = Path(__file__).with_name("result-schema.json")


def load_schema(path):
    with path.open() as fh:
        schema = json.load(fh)

    metrics = schema.get("metrics")
    if not isinstance(metrics, list):
        raise ValueError("schema.metrics must be an array")
    keys = [metric.get("key") for metric in metrics]
    if any(not isinstance(key, str) or not key for key in keys):
        raise ValueError("every metric must have a non-empty key")
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        raise ValueError(f"duplicate metric keys: {', '.join(duplicates)}")
    return schema, {metric["key"]: metric for metric in metrics}


def type_matches(value, expected):
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "object":
        return isinstance(value, dict)
    if expected == "number_array":
        return isinstance(value, list) and all(
            isinstance(item, (int, float)) and not isinstance(item, bool)
            for item in value
        )
    return False


def validate_value(value, spec, location):
    if value is None:
        return [] if spec.get("nullable", False) else [f"{location}: null is not allowed"]

    expected = spec.get("type")
    if not type_matches(value, expected):
        return [f"{location}: expected {expected}, got {type(value).__name__}"]

    errors = []
    if spec.get("nonempty") and not value:
        errors.append(f"{location}: must not be empty")
    if spec.get("nonnegative"):
        values = value if expected == "number_array" else [value]
        if any(not math.isfinite(item) or item < 0 for item in values):
            errors.append(f"{location}: must contain only finite nonnegative values")
    if expected == "object":
        properties = spec.get("properties", {})
        missing = sorted(set(properties) - set(value))
        if missing:
            errors.append(f"{location}: missing keys: {', '.join(missing)}")
        for key in sorted(set(properties) & set(value)):
            errors.extend(validate_value(value[key], properties[key], f"{location}.{key}"))
    return errors


def validate_document(document, schema, metrics):
    if not isinstance(document, dict):
        return ["document: expected object"]

    errors = []
    envelope = schema.get("document", {})
    missing = sorted(set(envelope) - set(document))
    if missing:
        errors.append(f"document: missing keys: {', '.join(missing)}")

    for key in sorted(set(envelope) & set(document)):
        spec = envelope[key]
        if spec.get("type") == "metrics":
            results = document[key]
            if not isinstance(results, dict):
                errors.append(f"document.{key}: expected object, got {type(results).__name__}")
                continue
            missing_metrics = sorted(set(metrics) - set(results))
            extra_metrics = sorted(set(results) - set(metrics))
            if missing_metrics:
                errors.append(
                    f"document.{key}: missing metrics: {', '.join(missing_metrics)}"
                )
            if extra_metrics:
                errors.append(
                    f"document.{key}: unknown metrics: {', '.join(extra_metrics)}"
                )
            for metric in sorted(set(metrics) & set(results)):
                errors.extend(
                    validate_value(
                        results[metric], metrics[metric], f"document.{key}.{metric}"
                    )
                )
        else:
            errors.extend(validate_value(document[key], spec, f"document.{key}"))
    return errors


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
