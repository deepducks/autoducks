#!/usr/bin/env python3
"""
Validate and sanitize /tmp/triage-decisions.json deterministically.

The product-agent LLM writes only the decision file; nothing it says is
trusted at face value. This checker enforces the named-priority vocabulary,
the confidence floor, and the per-run close cap before post.sh is allowed to
apply anything — in the spirit of core/robustness/parse-plan.py.

On a structurally invalid decision file (missing, empty, not JSON, or not a
JSON object), writes a diagnostic to REPORT_FILE and exits 1 — the caller
must apply nothing. Individual malformed/rejected entries within an otherwise
valid file are dropped silently into the report and do NOT fail the run
(exit 0); dropping bad entries while keeping the good ones is normal
operation, not a parse failure.

Usage:
  validate-triage-decisions.py <decisions.json> <validated-out.json> <confidence_threshold> <max_closes_per_run>
"""
import json
import os
import sys
from pathlib import Path

REPORT_FILE = os.environ.get("REPORT_FILE", "/tmp/triage-validation-report.json")

PRIORITY_ENUM = ["Critical", "High", "Medium", "Low"]
PRIORITY_LOOKUP = {p.lower(): p for p in PRIORITY_ENUM}

KIND_ENUM = ["Bug", "Feature"]
KIND_LOOKUP = {k.lower(): k for k in KIND_ENUM}

CONFIDENCE_RANK = {"low": 0, "medium": 1, "high": 2}


def write_report(report: dict) -> None:
    Path(REPORT_FILE).write_text(json.dumps(report, indent=2))


def fail(reason: str) -> None:
    write_report({"ok": False, "reason": reason})
    sys.stderr.write(f"::error title=triage decisions parse::{reason}\n")
    sys.exit(1)


def as_issue_number(value):
    """Coerce to a positive int, or None if not a valid issue number."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str) and value.strip().lstrip("-").isdigit():
        n = int(value.strip())
        return n if n > 0 else None
    return None


def validate_priorities(raw, dropped: list) -> list:
    if raw is None:
        return []
    if not isinstance(raw, list):
        dropped.append({"section": "priorities", "reason": "`priorities` is not an array; ignored entirely"})
        return []

    accepted = []
    seen_issues = set()
    for entry in raw:
        if not isinstance(entry, dict):
            dropped.append({"section": "priorities", "entry": entry, "reason": "entry is not an object"})
            continue

        issue = as_issue_number(entry.get("issue"))
        if issue is None:
            dropped.append({"section": "priorities", "entry": entry, "reason": "missing/invalid `issue`"})
            continue

        priority_raw = entry.get("priority")
        priority = PRIORITY_LOOKUP.get(str(priority_raw).lower()) if isinstance(priority_raw, str) else None
        if priority is None:
            dropped.append({
                "section": "priorities", "issue": issue,
                "reason": f"`priority` {priority_raw!r} is outside Critical|High|Medium|Low",
            })
            continue

        if issue in seen_issues:
            dropped.append({"section": "priorities", "issue": issue, "reason": "duplicate entry for this issue; first one wins"})
            continue
        seen_issues.add(issue)

        accepted.append({
            "issue": issue,
            "priority": priority,
            "rationale": entry.get("rationale") if isinstance(entry.get("rationale"), str) else "",
        })

    return accepted


def validate_classifications(raw, dropped: list) -> list:
    if raw is None:
        return []
    if not isinstance(raw, list):
        dropped.append({"section": "classifications", "reason": "`classifications` is not an array; ignored entirely"})
        return []

    accepted = []
    seen_issues = set()
    for entry in raw:
        if not isinstance(entry, dict):
            dropped.append({"section": "classifications", "entry": entry, "reason": "entry is not an object"})
            continue

        issue = as_issue_number(entry.get("issue"))
        if issue is None:
            dropped.append({"section": "classifications", "entry": entry, "reason": "missing/invalid `issue`"})
            continue

        kind_raw = entry.get("kind")
        kind = KIND_LOOKUP.get(str(kind_raw).lower()) if isinstance(kind_raw, str) else None
        if kind is None:
            dropped.append({
                "section": "classifications", "issue": issue,
                "reason": f"`kind` {kind_raw!r} is outside Bug|Feature",
            })
            continue

        if issue in seen_issues:
            dropped.append({"section": "classifications", "issue": issue, "reason": "duplicate entry for this issue; first one wins"})
            continue
        seen_issues.add(issue)

        accepted.append({
            "issue": issue,
            "kind": kind,
            "rationale": entry.get("rationale") if isinstance(entry.get("rationale"), str) else "",
        })

    return accepted


def validate_duplicates(raw, confidence_threshold: str, max_closes: int, dropped: list) -> list:
    if raw is None:
        return []
    if not isinstance(raw, list):
        dropped.append({"section": "duplicates", "reason": "`duplicates` is not an array; ignored entirely"})
        return []

    threshold_rank = CONFIDENCE_RANK.get(str(confidence_threshold).lower(), CONFIDENCE_RANK["high"])

    cleaned = []
    seen_dup_issues = set()
    seen_canonicals = set()
    for entry in raw:
        if not isinstance(entry, dict):
            dropped.append({"section": "duplicates", "entry": entry, "reason": "entry is not an object"})
            continue

        canonical = as_issue_number(entry.get("canonical"))
        if canonical is None:
            dropped.append({"section": "duplicates", "entry": entry, "reason": "missing/invalid `canonical`"})
            continue

        confidence_raw = entry.get("confidence")
        confidence = str(confidence_raw).lower() if isinstance(confidence_raw, str) else None
        if confidence not in CONFIDENCE_RANK:
            dropped.append({
                "section": "duplicates", "canonical": canonical,
                "reason": f"`confidence` {confidence_raw!r} is outside high|medium|low",
            })
            continue

        dup_raw = entry.get("duplicates")
        if not isinstance(dup_raw, list) or not dup_raw:
            dropped.append({"section": "duplicates", "canonical": canonical, "reason": "`duplicates` is missing or empty"})
            continue

        dup_issues = []
        for d in dup_raw:
            n = as_issue_number(d)
            if n is None:
                dropped.append({"section": "duplicates", "canonical": canonical, "entry": d, "reason": "invalid duplicate issue number"})
                continue
            if n == canonical:
                dropped.append({"section": "duplicates", "canonical": canonical, "entry": d, "reason": "canonical listed as its own duplicate"})
                continue
            dup_issues.append(n)

        if not dup_issues:
            dropped.append({"section": "duplicates", "canonical": canonical, "reason": "no valid duplicate issue numbers remained"})
            continue

        if CONFIDENCE_RANK[confidence] < threshold_rank:
            dropped.append({
                "section": "duplicates", "canonical": canonical,
                "reason": f"confidence '{confidence}' below threshold '{confidence_threshold}'",
            })
            continue

        if canonical in seen_dup_issues:
            dropped.append({"section": "duplicates", "canonical": canonical, "reason": "canonical was already closed as a duplicate in another group"})
            continue

        # Cross-group dedup: an issue can only be folded into one canonical.
        deduped_dups = []
        for n in dup_issues:
            if n in seen_dup_issues or n in seen_canonicals:
                dropped.append({"section": "duplicates", "canonical": canonical, "entry": n, "reason": "issue already claimed by another group"})
                continue
            deduped_dups.append(n)
            seen_dup_issues.add(n)

        if not deduped_dups:
            continue

        seen_canonicals.add(canonical)
        cleaned.append({
            "canonical": canonical,
            "duplicates": deduped_dups,
            "confidence": confidence,
            "rationale": entry.get("rationale") if isinstance(entry.get("rationale"), str) else "",
        })

    # Enforce max_closes_per_run: greedily keep whole groups, in the order
    # given, until the next group would push the total over the cap.
    accepted = []
    total_closes = 0
    for group in cleaned:
        n = len(group["duplicates"])
        if total_closes + n > max_closes:
            dropped.append({
                "section": "duplicates", "canonical": group["canonical"],
                "reason": f"would exceed max_closes_per_run={max_closes} ({total_closes}/{max_closes} already committed)",
            })
            continue
        total_closes += n
        accepted.append(group)

    return accepted


def main() -> None:
    if len(sys.argv) != 5:
        sys.stderr.write(
            "usage: validate-triage-decisions.py <decisions.json> <validated-out.json> "
            "<confidence_threshold> <max_closes_per_run>\n"
        )
        sys.exit(2)

    in_path, out_path, confidence_threshold, max_closes_raw = sys.argv[1:5]

    try:
        max_closes = int(max_closes_raw)
    except ValueError:
        max_closes = 5

    if not Path(in_path).exists():
        fail(f"Decision file not found: {in_path}")

    text = Path(in_path).read_text()
    if not text.strip():
        fail("Decision file is empty.")

    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        fail(f"Decision file is not valid JSON: {e}")

    if not isinstance(data, dict):
        fail("Decision file must be a JSON object with `priorities` and `duplicates` keys.")

    dropped = []
    priorities = validate_priorities(data.get("priorities"), dropped)
    duplicates = validate_duplicates(data.get("duplicates"), confidence_threshold, max_closes, dropped)
    classifications = validate_classifications(data.get("classifications"), dropped)

    Path(out_path).write_text(json.dumps(
        {"priorities": priorities, "duplicates": duplicates, "classifications": classifications}, indent=2
    ))

    write_report({
        "ok": True,
        "accepted_priorities": len(priorities),
        "accepted_duplicate_groups": len(duplicates),
        "accepted_closes": sum(len(g["duplicates"]) for g in duplicates),
        "accepted_classifications": len(classifications),
        "dropped": dropped,
    })

    print(f"Validated {len(priorities)} priorities, {len(duplicates)} duplicate groups -> {out_path}")


if __name__ == "__main__":
    main()
