# PR review prompt (agent-agnostic)

You are reviewing a pull request for the repository `{{REPO}}`, PR #{{PR_NUMBER}}
at head SHA `{{HEAD_SHA}}`. The diff is included verbatim below the `---` line.

Focus on:

- Correctness bugs, race conditions, and regressions introduced by this diff.
- Security issues at trust boundaries (input handling, command injection,
  secrets, auth).
- Violations of house rules captured in `CLAUDE.md` (tests-first, no test
  mutation to make green, no silently-swallowed exceptions, no commented-out
  code blocks).
- Missing or insufficient tests for new behavior.

Do not flag style preferences, naming choices, or speculative refactors.

Return **exactly one** JSON object on stdout — no prose, no Markdown fence:

```
{
  "verdict": "approve" | "request_changes" | "block",
  "summary": "one-paragraph summary of the change and your decision",
  "concerns": [
    { "severity": "high" | "medium" | "low", "message": "specific, actionable concern with file:line if applicable" }
  ]
}
```

Verdict semantics:

- `approve` — the diff is correct, safe, and tested. `concerns` may still
  contain `low`-severity nits.
- `request_changes` — there is at least one `high` or `medium` concern that
  must be addressed before merge.
- `block` — the diff cannot be reviewed at all (e.g. unreviewable scope, the
  branch is in a broken state, or the change is fundamentally the wrong
  approach). Use sparingly.

---

{{DIFF}}
