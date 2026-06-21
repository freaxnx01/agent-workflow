#!/usr/bin/env python3
"""Fail the build when any method exceeds a maximum executable-line count.

Reads one or more Code Metrics XML reports (as produced by the
Microsoft.CodeAnalysis.Metrics MSBuild target) and inspects every ``<Method>``
element's ``ExecutableLines`` metric.

Two independent failure modes, both exit non-zero:

1. Over-limit  — at least one method's ``ExecutableLines`` exceeds ``--max``.
2. Zero-methods — no ``<Method>`` element carrying an ``ExecutableLines`` metric
   was found in any input. A metrics run that silently scans nothing is the
   worst failure mode: it looks green while measuring nothing. We refuse it.

Exit codes:
  0  every method within the limit AND at least one method was scanned
  1  over-limit method(s) found, or zero methods scanned (the guard)
  2  usage error / unreadable input
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def _local(tag: str) -> str:
    """Strip any XML namespace so matching is namespace-agnostic."""
    return tag.rsplit("}", 1)[-1]


def _executable_lines(method: ET.Element) -> int | None:
    """Return the ExecutableLines metric value for a <Method>, or None."""
    for metric in method.iter():
        if _local(metric.tag) != "Metric":
            continue
        if metric.get("Name") == "ExecutableLines":
            value = metric.get("Value")
            if value is None:
                return None
            try:
                return int(value)
            except ValueError:
                return None
    return None


class _UnsafeXml(ValueError):
    """Raised when input declares a DTD/DOCTYPE (XXE / billion-laughs vector)."""


def _safe_parse(path: Path) -> ET.Element:
    """Parse XML while refusing DTDs.

    The stdlib XML parsers expand external/internal entities by default, which
    enables XXE and billion-laughs attacks. Legitimate Code Metrics reports
    never contain a DTD, so we reject any input that declares one rather than
    pull in a third-party parser. Entities can only be defined via a DTD, so
    refusing DOCTYPE neutralises both attack classes.
    """
    data = path.read_bytes()
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise _UnsafeXml("input declares a DTD/entity; refusing to parse")
    return ET.fromstring(data)


def _methods(root: ET.Element):
    """Yield every <Method> element regardless of namespace/nesting."""
    for element in root.iter():
        if _local(element.tag) == "Method":
            yield element


def _method_name(method: ET.Element) -> str:
    return method.get("Name", "<unnamed>")


def scan(paths: list[Path], max_lines: int) -> tuple[int, list[str]]:
    """Return (methods_scanned, violations) across all input files."""
    scanned = 0
    violations: list[str] = []
    for path in paths:
        try:
            root = _safe_parse(path)
        except (ET.ParseError, OSError, _UnsafeXml) as exc:
            # A malformed/unreadable report counts as zero methods from this
            # file; we do not abort, so the zero-methods guard can still fire
            # with a clear message if nothing else is scannable.
            print(f"::warning::could not parse metrics XML {path}: {exc}")
            continue
        for method in _methods(root):
            lines = _executable_lines(method)
            if lines is None:
                continue
            scanned += 1
            if lines > max_lines:
                violations.append(
                    f"{path}: method '{_method_name(method)}' has "
                    f"{lines} executable lines (max {max_lines})"
                )
    return scanned, violations


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--max",
        type=int,
        default=40,
        help="maximum executable lines per method (default: 40)",
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        help="Code Metrics XML report file(s) to inspect",
    )
    args = parser.parse_args(argv)

    if args.max <= 0:
        print("::error::--max must be a positive integer", file=sys.stderr)
        return 2

    paths = [Path(p) for p in args.inputs]
    scanned, violations = scan(paths, args.max)

    if scanned == 0:
        print(
            "::error::method-size check scanned ZERO methods — refusing to "
            "report green on an empty/garbage metrics report"
        )
        return 1

    if violations:
        for violation in violations:
            print(f"::error::{violation}")
        print(f"method-size check failed: {len(violations)} method(s) over limit")
        return 1

    print(f"method-size check passed: {scanned} method(s) all within {args.max} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
