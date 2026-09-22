# Pipeline GitHub App setup

Without this, the pipeline still works — it implements issues and opens draft
PRs. What it cannot do is get those PRs' **required status checks to run**.

## Why it is needed

A PR opened with the ambient `GITHUB_TOKEN` is authored by `github-actions`.
Its `pull_request` workflow runs are created but stall at `action_required`,
awaiting manual approval. In a repo with required status checks the PR then
reports an empty `statusCheckRollup`, satisfies nothing, and sits `BLOCKED`
until a human approves the runs or pushes to the branch.

Observed on #363: three runs created at `07:27:15` stalled and resolved to
`failure`; a human push at `07:42` ran all of them green with no approval.

An App-authored PR does not have this problem. `agent-implement.yml` already
mints and uses an App token when one is configured (the
`Mint pipeline App token (optional)` step); the code path is inert only because
the secrets are unset.

## Setup

1. **Create the App.** GitHub → Settings → Developer settings → GitHub Apps →
   New GitHub App. Name it something like `<org>-pipeline`. Homepage URL can be
   the repo. Uncheck **Webhook → Active**.

2. **Repository permissions** — the minimum the pipeline uses:

   | Permission | Level | Used for |
   |---|---|---|
   | Contents | Read and write | Push the agent's branch |
   | Pull requests | Read and write | `gh pr create`, promote from draft |
   | Issues | Read and write | Run report comments, labels |

3. **Install it** on the repo (or the org, scoped to selected repositories).

4. **Generate a private key** — on the App's page, Generate a private key. A
   `.pem` downloads. Treat it as a credential: it is not recoverable, and
   anyone holding it can act as the App.

5. **Add two repository secrets:**

   ```bash
   gh secret set PIPELINE_APP_ID --body '<the numeric App ID>'
   gh secret set PIPELINE_APP_PRIVATE_KEY < path/to/private-key.pem
   ```

   `PIPELINE_APP_ID` is the numeric ID on the App's settings page, not its name.

6. **Delete the local `.pem`** once the secret is set.

## Verify it worked

Dispatch any issue, then on the PR the pipeline opens:

```bash
gh pr view <n> --json author,statusCheckRollup \
  --jq '{author: .author.login, checks: (.statusCheckRollup | length)}'
```

- `author` should be `app/<your-app-name>`, not `github-actions`.
- `checks` should be non-zero within a couple of minutes.

If it is still `github-actions`, the secret is not visible to the run — check
it is a **repository** secret on the repo the workflow runs in, and that the
App is installed on that repo.

## If you skip this

The pipeline stays usable: PRs are opened as drafts and are perfectly
reviewable. Each run whose checks cannot start says so — the issue gets an
`ai:checks-blocked` label and the run report carries a warning block naming
this document. Approve the runs by hand from the PR's Checks tab, or push any
commit to the branch, and they run normally.
