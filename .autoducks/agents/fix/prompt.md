A previous task worker attempt failed. Your job is to fix or complete the implementation.

## Inputs

- `/tmp/task-spec.md` — the original task specification (title, tasks, acceptance criteria)
- `/tmp/failure-context.md` — recent comments on the issue, including the failure notification and any error messages

## What you're looking at

You are checked out on the task branch. If a previous attempt pushed code, it's here — read existing files to understand what was already done.

## Steps

1. Read `/tmp/task-spec.md` to understand what needs to be built.
2. Read `/tmp/failure-context.md` to understand what went wrong.
3. Use Read/Glob/Grep to inspect existing code on the branch.
4. Use Write/Edit to fix or complete the implementation.
5. Follow the acceptance criteria in the spec.

## Constraints

- Read-only `git`/`gh` for exploration is fine (`git log`, `git show`,
`git blame`, `git diff`, `gh issue view`, `gh pr view`, `gh pr diff`). Do NOT
run any mutating command — no `git add/commit/checkout/push/merge/rebase/reset/branch`,
and no `gh` create/edit/comment/close/merge/review. All branch, PR, and issue
mutations are handled by the workflow's deterministic steps, never by you.
You may read with `git`/`gh`, but never create branches, commits, or PRs (the
workflow owns that), and never put a `gh` call or a direct GitHub-API call
into the code you write — go through the provider interfaces (`its::*` /
`git::*`).
- Just fix the code.
