"""Shared loading and validation for benchmark result documents."""

import json
import math
from pathlib import Path


DEFAULT_SCHEMA = Path(__file__).with_name("result-schema.json")


def load_schema(path=DEFAULT_SCHEMA):
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
    required = {
        key for key, spec in envelope.items()
        if spec.get("required", True)
    }
    missing = sorted(required - set(document))
    if missing:
        errors.append(f"document: missing keys: {', '.join(missing)}")

    for key in sorted(set(envelope) & set(document)):
        spec = envelope[key]
        if spec.get("type") == "metrics":
            results = document[key]
            if not isinstance(results, dict):
                errors.append(f"document.{key}: expected object, got {type(results).__name__}")
                continue
            raw_version = document.get("schema_version", 1)
            version = (
                raw_version
                if isinstance(raw_version, int) and not isinstance(raw_version, bool)
                else 1
            )
            active_metrics = {
                metric for metric, metric_spec in metrics.items()
                if metric_spec.get("introduced", 1) <= version
            }
            missing_metrics = sorted(active_metrics - set(results))
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
