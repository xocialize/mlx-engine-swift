#!/usr/bin/env python3
"""Assert the README status block against source and git.

The status block is the first thing a consumer reads, and it goes stale whenever ANY session
lands a capability, a registry row, or a tag — the numbers live in the prose, the truth lives in
the code, and nothing connects them. This is that connection.

Three assertions, all derived rather than remembered:

  1. the capability count matches `Capability`'s cases
  2. the contract version matches `ContractVersion.current`
  3. the quoted tag is the newest tag reachable from HEAD

(3) is the one that pays for the script: a status block quoting a tag that is not the newest
reachable is either a release whose docs were never refreshed, or a version bump that never got
tagged. Both have happened; the second was caught a day later by a consuming app rather than at
the commit that introduced it.

DELIBERATELY NOT CHECKED: the published/tracked package counts. Those live in the registry, which
carries in-flight rows from other sessions, so a count derived from it would fail on work that is
merely unfinished rather than wrong. A gate that cries wolf gets disabled.

This is a docs gate, not a runtime gate — nothing misbehaves at runtime if the prose drifts. It
runs on a plain checkout with no Swift toolchain, so it stays cheap enough to be worth keeping.

FAILS CLOSED. Every parse step raises if it cannot find what it expects: a lint that silently
finds nothing and reports success is worse than no lint, because it also removes the suspicion
that would have prompted a manual check.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
CAPABILITY = ROOT / "Sources/MLXToolKit/Capability.swift"
CONTRACT = ROOT / "Sources/MLXToolKit/ContractVersion.swift"


class LintError(Exception):
    """A drift, or a parse that failed — both are failures, neither is a pass."""


def strip_comments(swift: str) -> str:
    swift = re.sub(r"/\*.*?\*/", "", swift, flags=re.S)
    return re.sub(r"//[^\n]*", "", swift)


def enum_body(swift: str, decl: str) -> str:
    """The brace-matched body of `decl`, so sibling enums in the same file are not counted."""
    start = swift.find(decl)
    if start == -1:
        raise LintError(f"could not find `{decl}` — did the declaration move or get renamed?")
    open_brace = swift.find("{", start)
    if open_brace == -1:
        raise LintError(f"found `{decl}` but no opening brace after it")
    depth = 0
    for i in range(open_brace, len(swift)):
        if swift[i] == "{":
            depth += 1
        elif swift[i] == "}":
            depth -= 1
            if depth == 0:
                return swift[open_brace + 1 : i]
    raise LintError(f"unbalanced braces while reading `{decl}`")


def capability_count() -> int:
    body = enum_body(strip_comments(CAPABILITY.read_text()), "public enum Capability")
    # `case a, b` is legal and would otherwise count as one.
    names = [n.strip() for line in re.findall(r"^\s*case\s+(.+)$", body, flags=re.M)
             for n in line.split(",") if n.strip()]
    if not names:
        raise LintError("parsed the Capability enum but found no cases — the parser is wrong, "
                        "not the enum")
    return len(names)


def contract_version() -> str:
    text = CONTRACT.read_text()
    m = re.search(
        r"static\s+let\s+current\s*=\s*SemanticVersion\(\s*major:\s*(\d+),\s*"
        r"minor:\s*(\d+),\s*patch:\s*(\d+)\s*\)", text)
    if not m:
        raise LintError("could not read `ContractVersion.current` — did its initializer change "
                        "shape?")
    return ".".join(m.groups())


def status_block() -> str:
    """Only the status blockquote.

    Scoping matters: the README discusses historical contract versions further down ("Through
    v0.36.0 (contract 1.27.0) …"). Asserting against the whole file would flag that correct
    history as drift and make the gate useless.
    """
    lines = README.read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith(">") and "## Status" in line:
            break
    else:
        raise LintError("no `> ## Status` blockquote in README.md")
    block = []
    for line in lines[i:]:
        if not line.startswith(">"):
            break
        block.append(line.lstrip(">").strip())
    # Collapsed to a single line on purpose: this prose gets rewrapped constantly, and a claim
    # that happens to straddle a line break must not read as a missing claim.
    return " ".join(block)


def newest_reachable_tag() -> str:
    try:
        out = subprocess.run(["git", "describe", "--tags", "--abbrev=0", "HEAD"],
                             cwd=ROOT, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as exc:
        raise LintError(
            "`git describe --tags` failed. In CI this usually means a shallow checkout with no "
            "tags — set `fetch-depth: 0` on actions/checkout.\n"
            f"  git said: {exc.stderr.strip()}") from exc
    return out.stdout.strip()


def main() -> int:
    failures: list[str] = []
    try:
        block = status_block()

        m = re.search(r"\*\*all (\d+) of the contract['\u2019]s capabilities\*\*", block)
        if not m:
            raise LintError("status block no longer says \"**all N of the contract's "
                            "capabilities**\" — update this script alongside the wording")
        claimed_caps, actual_caps = int(m.group(1)), capability_count()
        if claimed_caps != actual_caps:
            failures.append(
                f"capability count: README says {claimed_caps}, Capability.swift has "
                f"{actual_caps}")

        m = re.search(r"capability contract \*\*([0-9]+\.[0-9]+\.[0-9]+)\*\*", block)
        if not m:
            raise LintError("status block no longer says \"capability contract **X.Y.Z**\" — "
                            "update this script alongside the wording")
        claimed_contract, actual_contract = m.group(1), contract_version()
        if claimed_contract != actual_contract:
            failures.append(
                f"contract version: README says {claimed_contract}, ContractVersion.current is "
                f"{actual_contract}")

        m = re.search(r"tagged \*\*(v[0-9]+\.[0-9]+\.[0-9]+)\*\*", block)
        if not m:
            raise LintError("status block no longer says \"tagged **vX.Y.Z**\" — update this "
                            "script alongside the wording")
        claimed_tag, actual_tag = m.group(1), newest_reachable_tag()
        if claimed_tag != actual_tag:
            failures.append(
                f"tag: README says {claimed_tag}, newest tag reachable from HEAD is "
                f"{actual_tag}.\n"
                f"      If {claimed_tag} is the intended release, it was never tagged or never "
                f"pushed.\n"
                f"      If {actual_tag} is, the status block was not refreshed with it.")
    except LintError as exc:
        print(f"status-block-lint: FAILED TO CHECK — {exc}", file=sys.stderr)
        return 2

    if failures:
        print("status-block-lint: README status block is out of date\n", file=sys.stderr)
        for f in failures:
            print(f"  ✗ {f}", file=sys.stderr)
        print("\nFix README.md's status block (or the source, if the block is right).",
              file=sys.stderr)
        return 1

    print(f"status-block-lint: ok — {actual_caps} capabilities, contract {actual_contract}, "
          f"tag {actual_tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
