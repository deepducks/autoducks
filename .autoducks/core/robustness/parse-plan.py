#!/usr/bin/env python3
"""
Parse /tmp/plan-body.md into /tmp/tasks.jsonl deterministically.

Replaces the former LLM-based splitter-agent. Runs in <1s instead of ~8min.

On failure, writes a human-readable error report to /tmp/parse-error.md
(used by the workflow's plan-agent retry step to give the agent specific
feedback about what to fix) and exits 1.

Usage:
  parse-plan.py <plan-body.md> <tasks.jsonl>
"""
import json
import os
import re
import sys
from pathlib import Path

ERROR_FILE = os.environ.get("PARSE_ERROR_FILE", "/tmp/parse-error.md")

HEADING_RE = re.compile(
    r"^### (?P<ref>\S+) — (?P<title>.+?) `priority:(?P<priority>P\d)`\s*$",
    re.MULTILINE,
)

SECTION_RE = re.compile(
    r"^\*\*(?P<name>Summary|Tasks|Acceptance Criteria|References):\*\*"
    r"\s*(?P<content>.*?)"
    r"(?=^\*\*(?:Summary|Tasks|Acceptance Criteria|References):\*\*|\Z)",
    re.DOTALL | re.MULTILINE,
)

TEMPLATE_HINT = (
    "Required structure inside `## Tasks`:\n\n"
    "```\n"
    "### T1 — Short title `priority:P0`\n\n"
    "**Summary:** <one sentence, optionally followed by a ```code``` block>\n\n"
    "**Tasks:**\n- [ ] action 1\n- [ ] action 2\n\n"
    "**Acceptance Criteria:**\n- [ ] criterion 1\n\n"
    "**References:** <optional>\n"
    "```\n\n"
    "All section markers must be at the start of a line, "
    "bold-colon (`**Name:**`). Section order is Summary → Tasks → "
    "Acceptance Criteria → optional References."
)


def fail(reason: str, hint: str = "", excerpt: str = "") -> None:
    """Write structured error feedback consumable by humans and the retry prompt."""
    parts = [f"## Plan parse failure\n\n{reason}\n"]
    if hint:
        parts.append(f"\n**Hint:** {hint}\n")
    if excerpt:
        snippet = excerpt[:600].rstrip()
        parts.append(f"\n**Excerpt from your output:**\n\n```\n{snippet}\n```\n")
    parts.append(f"\n{TEMPLATE_HINT}\n")
    parts.append(
        "\nPlease re-emit `/tmp/plan-body.md` matching this template exactly. "
        "Preserve your plan's content — only fix the formatting issue above.\n"
    )
    Path(ERROR_FILE).write_text("".join(parts))
    sys.stderr.write(f"::error title=plan parse::{reason}\n")
    if hint:
        sys.stderr.write(f"::error::hint: {hint}\n")
    sys.exit(1)


def extract_tasks_section(content: str) -> str:
    m = re.search(
        r"^## Tasks\s*\n(?P<body>.*?)(?=^## |\Z)",
        content,
        re.MULTILINE | re.DOTALL,
    )
    if not m:
        fail(
            "Missing `## Tasks` section in plan body.",
            hint="The plan must contain exactly one `## Tasks` heading with task blocks beneath it.",
            excerpt=content,
        )
    return m.group("body")


def split_task_blocks(tasks_section: str):
    matches = list(HEADING_RE.finditer(tasks_section))
    if not matches:
        fail(
            "No `### <ref> — <title> `priority:PN`` task headings found inside `## Tasks`.",
            hint="Each task must start with e.g. `### T1 — Short title `priority:P0``.",
            excerpt=tasks_section,
        )
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(tasks_section)
        yield m, tasks_section[start:end].strip()


def parse_task_body(body: str, ref: str) -> dict:
    sections = {sm.group("name"): sm.group("content").strip() for sm in SECTION_RE.finditer(body)}

    for required in ("Summary", "Tasks", "Acceptance Criteria"):
        if required not in sections:
            fail(
                f"Task `{ref}` is missing the `**{required}:**` section.",
                hint="Required sections in order: Summary, Tasks, Acceptance Criteria.",
                excerpt=body,
            )
        if not sections[required]:
            fail(f"Task `{ref}` has an empty `**{required}:**` section.", excerpt=body)

    for name in ("Tasks", "Acceptance Criteria"):
        if not any(ln.lstrip().startswith("- [ ]") for ln in sections[name].splitlines()):
            fail(
                f"Task `{ref}` has a `**{name}:**` section with no `- [ ]` checkboxes.",
                hint=f"{name} items must be written as GitHub checkboxes.",
                excerpt=sections[name],
            )

    return sections


def build_issue_body(sections: dict) -> str:
    parts = [
        "## Summary", "", sections["Summary"], "",
        "## Tasks", "", sections["Tasks"], "",
        "## Acceptance Criteria", "", sections["Acceptance Criteria"],
    ]
    if sections.get("References"):
        parts += ["", "## References", "", sections["References"]]
    return "\n".join(parts)


def coerce_ref(ref_str: str):
    try:
        return int(ref_str)
    except ValueError:
        if not re.fullmatch(r"T\d+", ref_str):
            fail(
                f"Invalid task ref `{ref_str}`. Must be either an integer (preserved task) or `Tn` (new task).",
                hint="Use `T1`, `T2`, ... for new tasks; use the real issue number for preserved tasks.",
            )
        return ref_str


def main() -> None:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: parse-plan.py <plan-body.md> <tasks.jsonl>\n")
        sys.exit(2)

    plan_path, out_path = sys.argv[1], sys.argv[2]

    if not Path(plan_path).exists():
        fail(f"Plan body file not found: {plan_path}")

    content = Path(plan_path).read_text()
    if not content.strip():
        fail("Plan body file is empty.")

    tasks_section = extract_tasks_section(content)

    entries = []
    for heading, body in split_task_blocks(tasks_section):
        ref_str = heading.group("ref")
        title = heading.group("title").strip()
        priority = heading.group("priority")
        sections = parse_task_body(body, ref_str)
        entries.append({
            "ref": coerce_ref(ref_str),
            "title": title,
            "body": build_issue_body(sections),
            "labels": [f"priority:{priority}"],
        })

    with open(out_path, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")

    print(f"Parsed {len(entries)} tasks → {out_path}")


if __name__ == "__main__":
    main()
