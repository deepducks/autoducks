# Security Guidelines

This file is a **copyable template**. It lives at `.autoducks/security-guidelines.md`
and is read by the autoducks **Reviewer** agent (currently the sole consumer)
as project-specific security context in addition to its built-in behavior.

If your repo's config points `review.security_guidelines` at a different
file, these rules travel with that path instead — copy this file there, adapt
the specifics, and delete what doesn't apply. Nothing else in the repo needs
to change for these rules to take effect: each rule below is self-contained
and states the requirement, the reason, and how to check it.

Every rule in this document is a **hard requirement** for code proposed or
merged by an autoducks agent. A change that violates one of these rules should
be flagged as a `blocker` finding in review, not a `nit`.

---

## 1. Every trigger surface calls the Authorization Gate first

**Rule:** Any code path that reacts to an untrusted external event — a
`/<verb>` issue/PR comment, a label added to an issue, an issue assignment, a
`workflow_dispatch`, or any other trigger surface — MUST call the
Authorization Gate (`.autoducks/core/security/authorize.sh`) as its first
step, before any other observable side effect (reacting with an emoji,
posting a comment, creating a branch, spending LLM budget).

```bash
# Correct: gate runs before anything else, non-zero exit stops the workflow
bash .autoducks/core/security/authorize.sh
# workflow step below is conditioned on: if: steps.authz.outcome == 'success'
```

**Why:** autoducks runs on public repositories where anyone can open an issue
or leave a comment. Without an authorization check as step 0, a stranger's
comment can trigger a workflow that spends the maintainer's LLM budget,
creates branches, and opens PRs — a denial-of-wallet vector. The gate is the
single choke point between an untrusted event and a trusted action; adding a
new trigger surface without it re-opens that hole.

**How to check it:** for every new or modified workflow trigger, verify
`authorize.sh` (or a wrapper that calls it) runs before any comment, reaction,
branch, or LLM invocation on that path, and that a non-zero (`77`) exit from
the gate actually short-circuits the remaining steps.

---

## 2. Never echo, log, or print secrets

**Rule:** Tokens and credentials — `GH_TOKEN`, `ANTHROPIC_API_KEY`,
`AUTODUCKS_ORG_TOKEN`, `SOCK_PUPPET_TOKEN`, and any other secret-bearing
environment variable — must never be written to stdout/stderr, workflow logs,
`GITHUB_STEP_SUMMARY`, issue/PR comments, commit messages, or committed files.
This includes indirect leaks: don't `echo` a command line that embeds the
token, don't pass a token as a CLI argument that ends up in process listings
or shell history dumps, and don't include it in a debug dump of the
environment (`env`, `printenv`, `set -x` around a block that touches a
secret).

```bash
# Wrong — leaks the token into logs
echo "Authenticating with $GH_TOKEN"
curl "https://api.example.com/x?token=$GH_TOKEN"

# Right — token flows through an auth header or a provider function,
# never through a log line or a URL
curl -H "Authorization: Bearer $GH_TOKEN" "https://api.example.com/x"
```

**Why:** workflow logs, step summaries, and PR comments are often more widely
readable than the secret's original scope — a token that leaks into a public
log on a public repo is fully compromised, and rotating it is the only fix.
Agents write shell scripts and can inadvertently introduce a debug `echo` or
verbose curl command that would print a secret; this must be caught before
merge, not after a leak.

**How to check it:** grep new/changed shell code for the names of known
secret env vars combined with `echo`, `printf`, `cat <<<`, `set -x`, or
inclusion in a URL query string. Flag any match as a blocker unless the value
is provably not a secret at that call site.

---

## 3. Untrusted text must be quoted and validated before reaching a shell

**Rule:** Comment bodies, issue/PR titles, issue bodies, and any other
freeform text authored by an external actor are **untrusted input**. Before
such text is interpolated into a shell command, used as a filename, or passed
to `eval`, it must be:

- passed through a properly quoted variable (`"$var"`, never bare `$var` or
  string-concatenated into a command), and
- validated or sanitized against an explicit allowlist/pattern when it's used
  to control branching, file paths, or command selection (e.g. a slash
  command verb parsed from a comment body).

```bash
# Wrong — untrusted comment text splices directly into a shell command
eval "grep $comment_body file.txt"
git checkout "$(echo "$issue_title" | tr ' ' '-')"

# Right — untrusted text stays a single quoted argument, never evaluated
grep -- "$comment_body" file.txt
slug="$(printf '%s' "$issue_title" | sed 's/[^a-zA-Z0-9-]/-/g')"
```

**Why:** an issue title or comment body is the one artifact in the pipeline
that a fully untrusted, unauthenticated GitHub user can fully control. If
that text ever reaches `eval`, an unquoted shell expansion, or a filesystem
path without validation, it becomes an injection vector — the classic path
from "opened an issue" to "arbitrary code execution in the runner." This
holds even for actors who pass the Authorization Gate (rule 1): the gate
controls *who* can trigger an agent, not what the LLM or the surrounding
shell scripts do with the *content* that actor supplied.

**How to check it:** for every place a comment body, issue title, PR title,
or other user-authored string is read, trace where it's used. Flag any
unquoted shell interpolation, any `eval`/`sh -c` built from that string, and
any use of that string as a path component without a sanitizing
transformation first.

---

## 4. Don't bypass the provider abstractions

**Rule:** Code must talk to GitHub (or any other ITS/Git/LLM backend) through
the provider interfaces — `.autoducks/providers/its/interface.sh`,
`.autoducks/providers/git/interface.sh`, `.autoducks/providers/llm/`, and the
`its::*` / `git::*` functions they expose — not by calling `gh`, `curl`, or a
vendor SDK directly from agent code, workflow steps, or scripts outside the
provider directories.

```bash
# Wrong — reaches around the ITS provider straight to gh/curl
gh issue comment "$ISSUE_NUM" --body "$body"

# Right — goes through the provider function, which the concrete
# provider implementation (e.g. providers/its/github/comment-issue.sh)
# backs with whatever the active ITS actually is
its::comment_issue "$ISSUE_NUM" "$body"
```

**Why:** the provider layer is what makes autoducks portable across issue
trackers, git hosts, and LLM vendors — swapping `AUTODUCKS_ITS_PROVIDER` from
`github` to something else should require changing provider implementations,
not every call site. Bypassing the abstraction also routes around
provider-level safeguards (e.g. consistent auth handling, consistent error
handling) that the interface functions are relied upon to provide.

**How to check it:** for new or changed code, look for direct `gh <cmd>`,
`curl` to a known ITS/Git/LLM API host, or a vendor SDK import outside
`.autoducks/providers/*/`. Flag any such call as a violation unless it lives
inside a provider implementation file itself.

---

## Using this template

- Copy this file to `.autoducks/security-guidelines.md` in a new repo (or
  point your config at a different path) and adapt the specifics —
  environment variable names, provider directory paths, trigger surfaces —
  to match that repo's actual layout.
- Keep every rule self-contained: a rule that says "see the other file for
  details" stops being useful the moment this file is copied somewhere else
  without that other file. State the requirement, the reason, and the check
  inline, as done above.
- Treat violations of any rule here as review blockers, not style nits —
  each one maps directly to a concrete way an untrusted actor could spend
  budget, exfiltrate a secret, or run arbitrary code.
