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

- Do NOT run `git` commands. The workflow handles git operations.
- Do NOT create branches, commits, or pull requests.
- Do NOT call the GitHub API.
- Just fix the code.
