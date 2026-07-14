#!/usr/bin/env python3
"""
Parse /tmp/tactical-body.md into /tmp/tasks.jsonl deterministically.

Replaces the former LLM-based splitter-agent. Runs in <1s instead of ~8min.

On failure, writes a human-readable error report to /tmp/parse-error.md
(used by the workflow's plan-agent retry step to give the agent specific
feedback about what to fix) and exits 1.

Usage:
  parse-plan.py <tactical-body.md> <tasks.jsonl>
"""
import json
import os
import re
import sys
from pathlib import Path

ERROR_FILE = os.environ.get("PARSE_ERROR_FILE", "/tmp/parse-error.md")

HEADING_RE = re.compile(
    # Priority suffixes were retired (D14) but stay tolerated for plans
    # produced by older installs / revisions that mimic the old format.
    r"^### (?P<ref>\S+) — (?P<title>.+?)(?: `priority:P\d`)?\s*$",
    re.MULTILINE,
)

SECTION_RE = re.compile(
    r"^\*\*(?P<name>Summary|Tasks|Acceptance Criteria|References|Modules):\*\*"
    r"\s*(?P<content>.*?)"
    r"(?=^\*\*(?:Summary|Tasks|Acceptance Criteria|References|Modules):\*\*|\Z)",
    re.DOTALL | re.MULTILINE,
)

# Metarepo mode: a task may declare which submodules it touches via an optional
# `**Modules:**` section. Parsed as structured data (no fuzzy text parsing at
# commit time) and validated against .gitmodules so a typo fails at plan time.
_MODULE_TOKEN_RE = re.compile(r"[^\s,\[\]]+")


def submodule_paths():
    """Submodule paths declared in the nearest .gitmodules (empty list if none)."""
    root = Path.cwd()
    gm = None
    for d in [root, *root.parents]:
        cand = d / ".gitmodules"
        if cand.exists():
            gm = cand
            break
    if gm is None:
        return []
    paths = []
    for line in gm.read_text().splitlines():
        m = re.match(r"\s*path\s*=\s*(.+?)\s*$", line)
        if m:
            paths.append(m.group(1))
    return paths


def parse_modules(sections: dict, ref: str):
    """Extract + validate the optional per-task module list."""
    raw = sections.get("Modules", "")
    if not raw:
        return []
    mods = []
    seen = set()
    for tok in _MODULE_TOKEN_RE.findall(raw):
        tok = tok.strip("-`*")
        if tok and tok not in seen:
            seen.add(tok)
            mods.append(tok)
    if os.environ.get("AUTODUCKS_METAREPO") == "true":
        known = set(submodule_paths())
        unknown = [m for m in mods if m not in known]
        if unknown:
            fail(
                f"Task `{ref}` declares unknown module(s): {', '.join(unknown)}.",
                hint=(
                    "`**Modules:**` entries must be submodule paths from .gitmodules: "
                    + (", ".join(sorted(known)) if known else "(no submodules found)")
                ),
                excerpt=raw,
            )
    return mods

TEMPLATE_HINT = (
    "Required structure inside `## Tasks`:\n\n"
    "```\n"
    "### T1 — Short title\n\n"
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
        "\nPlease re-emit `/tmp/tactical-body.md` matching this template exactly. "
        "Preserve your plan's content — only fix the formatting issue above.\n"
    )
    Path(ERROR_FILE).write_text("".join(parts))
    sys.stderr.write(f"::error title=plan parse::{reason}\n")
    if hint:
        sys.stderr.write(f"::error::hint: {hint}\n")
    sys.exit(1)


FENCE_RE = re.compile(r"(`{3,}|~{3,})")


def _blank(line: str) -> str:
    """Blank a line's visible chars to spaces, keeping newlines (and offsets)."""
    return "".join(ch if ch in "\r\n" else " " for ch in line)


def mask_code_fences(text: str) -> str:
    """Return a copy of `text` with fenced code blocks blanked out.

    Every character inside a fenced code block (and the fence lines
    themselves) is replaced by a space, while newlines are preserved. The
    result is byte-for-byte the same length as the input, so match offsets
    computed on the masked copy map 1:1 back onto the original — letting us
    detect structure (headings, `**Name:**` markers) without being fooled by
    marker-like lines that appear *inside* example code blocks, then slice the
    real content (code blocks intact) from the original. Follows CommonMark:
    a fence opens on a line of >=3 backticks/tildes (indent <=3) and closes on
    a line of the same char, length >= the opener's, with no info string.
    """
    out = []
    in_fence = False
    fence_char = ""
    fence_len = 0
    for line in text.splitlines(keepends=True):
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        m = FENCE_RE.match(stripped) if indent <= 3 else None
        if not in_fence:
            if m:
                in_fence, fence_char, fence_len = True, m.group(1)[0], len(m.group(1))
                out.append(_blank(line))
            else:
                out.append(line)
        else:
            out.append(_blank(line))
            if (
                m is not None
                and m.group(1)[0] == fence_char
                and len(m.group(1)) >= fence_len
                and stripped[len(m.group(1)):].strip() == ""
            ):
                in_fence, fence_char, fence_len = False, "", 0
    return "".join(out)


def extract_tasks_section(content: str, masked: str):
    m = re.search(
        r"^## Tasks\s*\n(?P<body>.*?)(?=^## |\Z)",
        masked,
        re.MULTILINE | re.DOTALL,
    )
    if not m:
        fail(
            "Missing `## Tasks` section in plan body.",
            hint="The plan must contain exactly one `## Tasks` heading with task blocks beneath it.",
            excerpt=content,
        )
    s, e = m.span("body")
    return content[s:e], masked[s:e]


def split_task_blocks(tasks_content: str, tasks_masked: str):
    matches = list(HEADING_RE.finditer(tasks_masked))
    if not matches:
        fail(
            "No `### <ref> — <title>` task headings found inside `## Tasks`.",
            hint="Each task must start with e.g. `### T1 — Short title`.",
            excerpt=tasks_content,
        )
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(tasks_masked)
        # Slices stay offset-aligned between original and masked; parse_task_body
        # strips per-section, so we hand over the raw (unstripped) slices here.
        yield m, tasks_content[start:end], tasks_masked[start:end]


def parse_task_body(body: str, body_masked: str, ref: str) -> dict:
    sections = {
        sm.group("name"): body[slice(*sm.span("content"))].strip()
        for sm in SECTION_RE.finditer(body_masked)
    }

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


def build_issue_body(sections: dict, modules=None) -> str:
    parts = [
        "## Summary", "", sections["Summary"], "",
        "## Tasks", "", sections["Tasks"], "",
        "## Acceptance Criteria", "", sections["Acceptance Criteria"],
    ]
    if sections.get("References"):
        parts += ["", "## References", "", sections["References"]]
    if modules:
        # Human-readable section + a machine marker the developer (drift guard)
        # and Maestro (delivery union) read as structured data.
        parts += ["", "## Modules", "", ", ".join(f"`{m}`" for m in modules)]
        parts += ["", f"<!-- autoducks:modules: {','.join(modules)} -->"]
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
        sys.stderr.write("usage: parse-plan.py <tactical-body.md> <tasks.jsonl>\n")
        sys.exit(2)

    plan_path, out_path = sys.argv[1], sys.argv[2]

    if not Path(plan_path).exists():
        fail(f"Plan body file not found: {plan_path}")

    content = Path(plan_path).read_text()
    if not content.strip():
        fail("Plan body file is empty.")

    # Detect structure on a copy with code fences blanked out, so marker-like
    # lines inside example code blocks can't be mistaken for real headings or
    # sections; content is always sliced from the original (fences intact).
    masked = mask_code_fences(content)

    tasks_content, tasks_masked = extract_tasks_section(content, masked)

    entries = []
    for heading, body, body_masked in split_task_blocks(tasks_content, tasks_masked):
        ref_str = heading.group("ref")
        title = heading.group("title").strip()
        sections = parse_task_body(body, body_masked, ref_str)
        modules = parse_modules(sections, ref_str)
        entries.append({
            "ref": coerce_ref(ref_str),
            "title": title,
            "body": build_issue_body(sections, modules),
            "labels": ["Task"],
            "modules": modules,
        })

    with open(out_path, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")

    print(f"Parsed {len(entries)} tasks → {out_path}")


if __name__ == "__main__":
    main()
