# AGENT-NOTES

Repo-local, agent-facing context for `agent-workflow` that the generated
`CLAUDE.md` can't carry (it is rebuilt from `.ai/base-instructions.md` +
`.ai/stacks/ci.md` by `/sync-ai-instructions` and any edit there is overwritten).

---

## Branch protection: `main` is protected, but admins are exempt

`CLAUDE.md` states that `main` requires passing CI, at least one PR review, and no
direct push. That is configured correctly — **but it does not apply to the repo
owner.**

Current settings (classic branch protection; no rulesets):

| Setting | Value |
|---|---|
| Required status check | `gate-selftest` (GitHub Actions) |
| ↳ strict | true — branch must be up to date before merge |
| Required approving reviews | 1 |
| **Enforce on admins** | **false** ← the exemption |
| Force pushes / deletions | blocked |
| Signatures / linear history / conversation resolution | not required |

Because `enforce_admins` is `false`, a push to `main` with an admin token succeeds
even when the required check hasn't reported yet. GitHub prints:

```text
remote: Bypassed rule violations for refs/heads/main:
remote: - Required status check "gate-selftest" is expected.
```

**This is not an error and not a failed gate.** The push lands, and `gate-selftest`
then runs against the new commit on `main` — check its result rather than assuming
the bypass skipped it.

### When a direct push is acceptable

Only for trivial non-code edits — docs, comments, typos — per the exception in
`.ai/base-instructions.md` ("trivial non-code edits may skip review and push
directly; CI must still pass"). Anything touching `.github/workflows/`, `scripts/`,
`gate-tests/` or `commands/` goes through a PR, exemption or not: those are the
pipeline itself, and the gates exist to catch exactly those changes.

The protection is a guardrail against automation mistakes, not against the owner.
Treat the bypass as deliberate and rare; if bypass messages start appearing on
source changes, that's a signal to reconsider — either raise the discipline or set
`enforce_admins: true`.

---

## Pushing requires a token bridge

The ambient git credential on this machine may resolve to the wrong GitHub account
(symptom: `Permission to freaxnx01/agent-workflow.git denied to <other-account>`,
HTTP 403). The correct token lives in a direnv `.envrc` one level up from the repos
directory, and the agent shell does not trigger direnv hooks.

Git's credential helper reads `GITHUB_TOKEN`, while the `.envrc` provides `GH_TOKEN`,
so bridge the name inline:

```bash
direnv exec ~/repos/github/freaxnx01 \
  bash -c 'GITHUB_TOKEN="$GH_TOKEN" git push origin main'
```

Prefer this over suggesting an interactive `gh auth login`.
