#!/usr/bin/env python3
"""Verify that pull requests reference GitHub issues or PRs with milestones."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys


REFERENCE_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_.-])(?:(?P<repo>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#(?P<number>[1-9][0-9]*)\b"
)
GH_REFERENCE_PATTERN = re.compile(r"\bGH-(?P<number>[1-9][0-9]*)\b")


def run(args: list[str]) -> str:
    process = subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if process.returncode:
        raise SystemExit(
            f"command failed: {shlex.join(args)}\n{process.stderr.strip()}"
        )
    return process.stdout


def split_repo(repo: str) -> tuple[str, str]:
    parts = (repo or "").split("/", 1)
    if len(parts) != 2 or not all(parts):
        raise SystemExit("--repo must use OWNER/NAME format")
    return parts[0], parts[1]


def issue_references(text: str, default_repo: str) -> list[tuple[str, int]]:
    references: set[tuple[str, int]] = set()
    for match in REFERENCE_PATTERN.finditer(text):
        repo = match.group("repo") or default_repo
        references.add((repo, int(match.group("number"))))
    for match in GH_REFERENCE_PATTERN.finditer(text):
        references.add((default_repo, int(match.group("number"))))
    return sorted(references)


def fetch_issue(repo: str, number: int) -> dict[str, object]:
    """Fetch a GitHub issue payload, which also covers pull requests by number."""
    owner, name = split_repo(repo)
    payload = run(["gh", "api", f"repos/{owner}/{name}/issues/{number}"])
    return json.loads(payload)


def reference_label(reference_repo: str, default_repo: str, number: int) -> str:
    if reference_repo == default_repo:
        return f"#{number}"
    return f"{reference_repo}#{number}"


def verify_references(
    default_repo: str,
    references: list[tuple[str, int]],
    issue_fetcher=fetch_issue,
) -> list[str]:
    if not references:
        return ["Pull request title or body must reference a GitHub issue."]

    failures: list[str] = []
    for repo, number in references:
        issue = issue_fetcher(repo, number)
        milestone = issue.get("milestone")
        if not isinstance(milestone, dict):
            failures.append(
                "Referenced item "
                f"{reference_label(repo, default_repo, number)} "
                "must be assigned to a milestone."
            )
    return failures


def verify_pull_request(
    repo: str,
    number: int,
    issue_fetcher=fetch_issue,
) -> list[str]:
    pull_request = issue_fetcher(repo, number)
    title = str(pull_request.get("title") or "")
    body = str(pull_request.get("body") or "")
    references = [
        reference
        for reference in issue_references(f"{title} {body}", repo)
        if reference != (repo, number)
    ]
    return verify_references(repo, references, issue_fetcher=issue_fetcher)


def self_test() -> None:
    references = issue_references(
        "Follow-up for #12, GH-7, and octo/example#9. Duplicate #12 is ignored.",
        "test-owner/test-repo",
    )
    assert references == [
        ("octo/example", 9),
        ("test-owner/test-repo", 7),
        ("test-owner/test-repo", 12),
    ]
    assert issue_references("Ignored #0 and GH-0 references", "test-owner/test-repo") == []

    failures = verify_references("test-owner/test-repo", [])
    assert failures == ["Pull request title or body must reference a GitHub issue."]

    fake_issues = {
        ("test-owner/test-repo", 11): {"milestone": {"title": "Version 0.2.3"}},
        ("octo/example", 9): {},
    }
    failures = verify_references(
        "test-owner/test-repo",
        [
            ("test-owner/test-repo", 11),
            ("octo/example", 9),
        ],
        issue_fetcher=lambda repo, number: fake_issues[(repo, number)],
    )
    assert failures == ["Referenced item octo/example#9 must be assigned to a milestone."]

    fake_pull_request = {
        "title": "Fix follow-up for #11 and self-reference #16",
        "body": "",
        "milestone": None,
    }
    failures = verify_pull_request(
        "test-owner/test-repo",
        16,
        issue_fetcher=lambda repo, number: fake_pull_request
        if number == 16
        else fake_issues[(repo, number)],
    )
    assert failures == []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="")
    parser.add_argument("--pr", type=int)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        if args.repo or args.pr is not None:
            raise SystemExit("--self-test cannot be combined with --repo or --pr")
        try:
            self_test()
        except AssertionError as exc:
            detail = f": {exc}" if str(exc) else ""
            raise SystemExit(
                f"PR issue milestone policy self-test failed{detail}"
            ) from exc
        print("PR issue milestone policy self-test passed")
        return 0

    if not args.repo or args.pr is None or args.pr <= 0:
        raise SystemExit("--repo and --pr are required unless --self-test is used")

    failures = verify_pull_request(args.repo, args.pr)
    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print("PR issue milestone policy passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
