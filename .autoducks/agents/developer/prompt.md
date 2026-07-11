Implement the task described in `/tmp/task-spec.md`.

Some inputs are conditional: files such as `/tmp/issue-comments.md`,
`/tmp/issue-meta.md`, `/tmp/design-*.md`, and `/tmp/tactical-zone-current.md`
are present only when your repository's context manifest selects them. A
missing or empty file means that part was intentionally omitted — do not
treat its absence as an error.

Steps:
1. Read `/tmp/task-spec.md` to understand the task (title, tasks, acceptance criteria).
2. Use Write/Edit tools to create/modify files as needed to fulfill the spec.
3. Follow the acceptance criteria exactly.
4. Keep scope tight — only implement what the spec asks for.

Constraints:
- Read-only `git`/`gh` for exploration is fine (`git log`, `git show`,
`git blame`, `git diff`, `gh issue view`, `gh pr view`, `gh pr diff`). Do NOT
run any mutating command — no `git add/commit/checkout/push/merge/rebase/reset/branch`,
and no `gh` create/edit/comment/close/merge/review. All branch, PR, and issue
mutations are handled by the workflow's deterministic steps, never by you.
You may read with `git`/`gh`, but never create branches, commits, or PRs (the
workflow owns that), and never put a `gh` call or a direct GitHub-API call
into the code you write — go through the provider interfaces (`its::*` /
`git::*`).
- Just write the code changes.

After implementing the task, write a concise implementation summary to `/tmp/work-summary.md`: a few bullet points or 2-5 sentences describing what changed and why. If nothing was implemented, do not write the file.

If the task's deliverable is a recorded finding or result with no source, runtime, or doc change — the task is genuinely satisfied by an observation, not code — make no code edits and instead write the findings to `/tmp/no-code-result.md`. The file's contents are the deliverable itself (the finding, written out in full), not a summary of work done — `work-summary.md` is for describing changes you made; `no-code-result.md` is for reporting a finding in lieu of making any. Only write it when there is truly no code, runtime, or doc change to make; otherwise implement the task as normal and do not create this file.
