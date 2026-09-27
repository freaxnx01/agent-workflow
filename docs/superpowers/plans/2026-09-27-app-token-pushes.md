# App-Token Pushes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every push the pipeline performs authenticate as the GitHub App, so the runs those pushes trigger no longer stall at `action_required`.

**Architecture:** Two jobs push, by two different mechanisms. The implement job's agent pushes with credentials `actions/checkout` persisted, so its checkout needs a `token:` — and the mint step must move above it. The review jobs push through `self-fix-pr.sh`, which injects `$GH_TOKEN` into the remote URL itself, so they need a mint step and a changed `GH_TOKEN` on one step, and no script change at all.

**Tech Stack:** GitHub Actions reusable-workflow YAML, `actions/create-github-app-token`, `actions/checkout`, `actionlint`, structural assertions in the existing Layer-1 bash suite.

**Spec:** `docs/superpowers/specs/2026-09-27-app-token-pushes-design.md`

## Prerequisite — the App needs the Workflows permission

This plan edits `.github/workflows/agent-implement.yml`, and **no push of that
file succeeds until the pipeline App is granted repository permission
`Workflows: Read and write` and the installation accepts it.** An Actions
`permissions:` block has no `workflows` key, so `GITHUB_TOKEN` can never push a
workflow-file change; a GitHub App can, but only once granted. Without it the
push is rejected with:

```text
! [remote rejected] ... (refusing to allow a GitHub App to create or update
  workflow `.github/workflows/agent-implement.yml` without `workflows` permission)
```

— and the run ends with no branch and no PR, losing the work. This predates
#430; it is also why #364 silently skipped its `.github/workflows/` edits twice.

Grant it at `https://github.com/settings/apps/<app>/permissions`, then accept
the new permission on the installation at
`https://github.com/settings/installations`. See `docs/PIPELINE-APP-SETUP.md`.

## Global Constraints

- Every new token reference is `${{ steps.app_token.outputs.token || github.token }}`. **The fallback is mandatory** — it is what keeps this a no-op for consumers without the App.
- **Only the two operations that push change.** Labels, comments, run reports and the auto-merge keep `github.token`.
- **Never pass an installation token between jobs via a job output.** Job outputs are not secret-masked. Each job mints its own.
- A job's mint step must appear **before** any checkout or step that consumes `steps.app_token.outputs.token`.
- The three `pipeline-ref` checkouts (`:445`, `:1015`, `:1399` on `main` before editing) fetch agent-workflow itself and keep the default token.
- The mint's `if:` tests `env.PIPELINE_APP_ID`, not `secrets.PIPELINE_APP_ID` — **the `secrets` context is unavailable in `if:`**. A job that adds a mint must also add the job-level `env:` line, or the condition evaluates empty and the step silently never runs.
- `actions/checkout` stays pinned to `11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`; `actions/create-github-app-token` to `fee1f7d63c2ff003460e3d139729b119787bc349  # v2.2.2`. No floating tags.
- Structural assertions strip YAML comments before matching, as the existing workflow guards do.
- Conventional Commits; scope `pipeline`.

**Line numbers below are as of `origin/main` at the time of writing.** They shift as you edit. Anchor on the quoted text, not the number.

---

### Task 1: The implement job — reorder the mint, token the checkout

**Files:**
- Modify: `.github/workflows/agent-implement.yml` (`implement` job, `:411-440`)
- Modify: `tests/run-script-tests.sh` (new assertions)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: in the `implement` job, `steps.app_token` is available to every step after the mint, including `Checkout consumer repo`. Task 2 adds the same pattern to the review jobs; Task 3 asserts across all three.

- [ ] **Step 1: Write the failing test**

Append to `tests/run-script-tests.sh`, immediately before its final summary block:

```bash
section "agent-implement.yml — pipeline pushes act as the App (#430)"

# Configuring the App made pipeline PRs App-authored, but every `git push` was
# still github-actions[bot], so the runs those pushes trigger stalled at
# action_required exactly as before. Observed on PR #424: opened by the App at
# 14:36 with checks running, then runs created at 14:47 with
# actor=github-actions[bot] stalled and the PR dropped to checks: 0.
WF430="$ROOT/.github/workflows/agent-implement.yml"

# Strip comments before asserting: the steps deliberately explain why the token
# is needed, and matching the whole file would count the explanation.
wf430_exec="$(grep -vE '^[[:space:]]*#' "$WF430")"

# The agent pushes with the credentials actions/checkout persists.
assert_equals "$(printf '%s' "$wf430_exec" | grep -c 'token: ..{ steps.app_token' || true)" "1" \
  "the consumer checkout receives the App token"

# Ordering: the mint must come before the checkout that consumes it. Compare
# line numbers within the implement job.
mint_line="$(grep -n 'id: app_token' "$WF430" | head -1 | cut -d: -f1)"
ckout_line="$(grep -n 'name: Checkout consumer repo' "$WF430" | head -1 | cut -d: -f1)"
if [[ -n "$mint_line" && -n "$ckout_line" ]] && (( mint_line < ckout_line )); then
  pass "the mint step precedes the consumer checkout it serves"
else
  fail "the mint step precedes the consumer checkout it serves" \
    "mint at ${mint_line:-none}, checkout at ${ckout_line:-none}"
fi

# The pipeline-ref checkouts fetch agent-workflow itself and must keep the
# default token — scoping the change.
assert_equals "$(printf '%s' "$wf430_exec" | grep -c 'ref: ..{ inputs.pipeline-ref' || true)" "3" \
  "the three pipeline-ref checkouts are still present and untouched"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A2 '✗' | head -12`
Expected: FAIL — no checkout carries a `token:`, and the mint currently sits
*after* the checkout.

- [ ] **Step 3: Move the mint above the checkout**

In the `implement` job the current order is:

```yaml
    steps:
      - name: Checkout consumer repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2

      - name: Mint pipeline App token (optional)
        ...
      - name: Warn when no pipeline App token is configured
        ...
```

Cut the **`Mint pipeline App token (optional)`** step and the
**`Warn when no pipeline App token is configured`** step, both entire, and paste
them directly after `steps:`, so the order becomes:

```yaml
    steps:
      - name: Mint pipeline App token (optional)
        ...unchanged...

      - name: Warn when no pipeline App token is configured
        ...unchanged...

      - name: Checkout consumer repo
        ...
```

The mint needs no working copy, so this reorder is free. The warn step moves
with it so the "no App token" warning still lands before any agent cost.

- [ ] **Step 4: Give the consumer checkout the token**

Replace the `implement` job's checkout with:

```yaml
      - name: Checkout consumer repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          # The agent pushes with the credentials this step persists
          # (persist-credentials defaults to true). Without a token here those
          # pushes are github-actions[bot], and the runs they trigger stall at
          # action_required even though the PR itself is App-authored (#430).
          # Falls back to github.token, so a consumer without the App is
          # unaffected.
          token: ${{ steps.app_token.outputs.token || github.token }}
```

- [ ] **Step 5: Run the tests and actionlint**

```bash
bash tests/run-script-tests.sh 2>&1 | tail -3
actionlint .github/workflows/agent-implement.yml
```

Expected: the three new assertions pass; `actionlint` clean.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/agent-implement.yml tests/run-script-tests.sh
git commit -m "fix(pipeline): let the implement job's agent push as the App

actions/checkout persists the token it used, so the agent's per-task pushes
were github-actions[bot] and the runs they triggered stalled at
action_required even though the PR was App-authored.

The mint step moves above the checkout because its output does not exist
yet at checkout time; create-github-app-token needs no working copy.

Refs #430"
```

---

### Task 2: The review jobs — mint a token, hand it to self-fix

**Files:**
- Modify: `.github/workflows/agent-implement.yml` — `ai_review_ai_merge` (job at `:985`, `runs-on` `:998`, `permissions` `:1000`, self-fix step `~:1565`) and `ai_review_human_merge` (job at `:1366`, `runs-on` `:1383`, `permissions` `:1385`, self-fix step `~:1222`)
- Modify: `tests/run-script-tests.sh` (extend Task 1's section)

**Interfaces:**
- Consumes: the mint-step block from Task 1 (same `id: app_token`, same pinned SHA).
- Produces: `steps.app_token` available in both review jobs. Task 3 asserts all three jobs together.

**`self-fix-pr.sh` is not modified.** It already injects whatever `GH_TOKEN` it
is given into the clone's remote URL (`:114-115`). It is simply handed
`${{ github.token }}` today.

- [ ] **Step 1: Write the failing test**

Append to the `#430` section added in Task 1:

```bash
# Both review jobs must mint their own token. Passing one between jobs via a
# job output is not an option: job outputs are not secret-masked.
assert_equals "$(printf '%s' "$wf430_exec" | grep -c 'id: app_token' || true)" "3" \
  "all three jobs mint an installation token"

# The mint's if: tests env.PIPELINE_APP_ID because the secrets context is not
# available in if:. Without the job-level env line the condition evaluates
# empty and the step silently never runs.
assert_equals "$(printf '%s' "$wf430_exec" | grep -c 'PIPELINE_APP_ID: ..{ secrets' || true)" "3" \
  "all three jobs declare PIPELINE_APP_ID at job level"

# self-fix pushes; it must not be handed the ambient token.
assert_equals "$(printf '%s' "$wf430_exec" | grep -c 'GH_TOKEN: ..{ steps.app_token' || true)" "8" \
  "both self-fix steps get the App token (6 implement-job callers + 2)"
```

**On that count of 8:** the `implement` job already carries **six** such lines
(verified on `origin/main`); the two self-fix steps bring it to eight. Confirm
the starting number on your checkout before implementing and use `starting + 2`:

```bash
grep -c 'GH_TOKEN: ..{ steps.app_token' .github/workflows/agent-implement.yml
```

**Note the pattern.** These greps use `..{` rather than a literal `${{`.
A `${{ ... }}` inside a single-quoted string nested in a command substitution
inside double quotes gets mangled by the shell and silently matches **zero**
lines — which reads as "the assertion is failing" rather than "the grep is
broken". `..{` matches the same text without the hazard.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run-script-tests.sh 2>&1 | grep -A2 '✗' | head -12`
Expected: FAIL — only one `id: app_token` and one job-level `PIPELINE_APP_ID`.

- [ ] **Step 3: Add the job-level env to both review jobs**

In **`ai_review_ai_merge`**, between `runs-on:` (`:998`) and `permissions:`
(`:1000`), insert:

```yaml
    env:
      # Mirrors the implement job: the mint step's `if:` tests this, because
      # the `secrets` context is not available in `if:`. Without it the
      # condition evaluates empty and the mint silently never runs (#430).
      PIPELINE_APP_ID: ${{ secrets.PIPELINE_APP_ID }}
```

In **`ai_review_human_merge`**, between `runs-on:` (`:1383`) and `permissions:`
(`:1385`), insert the identical block.

- [ ] **Step 4: Add the mint step to both review jobs**

In each review job, insert as the **first** step under `steps:` — before
`- name: Checkout consumer repo`:

```yaml
      - name: Mint pipeline App token (optional)
        # self-fix-pr.sh pushes, and injects whatever GH_TOKEN it is given into
        # the clone's remote URL. Without an App token here those pushes are
        # github-actions[bot] and their runs stall at action_required (#430).
        # Each job mints its own: an installation token must never travel
        # between jobs through a job output, which is not secret-masked.
        id: app_token
        if: ${{ env.PIPELINE_APP_ID != '' }}
        uses: actions/create-github-app-token@fee1f7d63c2ff003460e3d139729b119787bc349  # v2.2.2
        with:
          app-id: ${{ secrets.PIPELINE_APP_ID }}
          private-key: ${{ secrets.PIPELINE_APP_PRIVATE_KEY }}
```

**Leave both `Checkout consumer repo` steps alone.** They exist only so
`check-merge-envelope.sh` can read `.claude-auto-merge-blocklist`; they never
push.

- [ ] **Step 5: Hand the token to self-fix in both jobs**

In each review job's self-fix step — the one with `id: self_fix` whose `run:` is
`bash .claude-pipeline/scripts/self-fix-loop.sh` — change:

```yaml
          GH_TOKEN: ${{ github.token }}
```

to:

```yaml
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
```

Change **only** the `self_fix` steps. Other steps in these jobs post comments
and labels, which keep `github.token` by design.

- [ ] **Step 6: Run the tests and actionlint**

```bash
bash tests/run-script-tests.sh 2>&1 | tail -3
actionlint .github/workflows/agent-implement.yml
```

Expected: all `#430` assertions pass; `actionlint` clean.

- [ ] **Step 7: Verify no push step kept the ambient token**

```bash
grep -n 'id: self_fix' -A 4 .github/workflows/agent-implement.yml | grep GH_TOKEN
```

Expected: two lines, both `${{ steps.app_token.outputs.token || github.token }}`.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/agent-implement.yml tests/run-script-tests.sh
git commit -m "fix(pipeline): let self-fix push as the App

Both review jobs ran entirely on github.token, so self-fix's pushes were
github-actions[bot] and their runs stalled at action_required.

Each job mints its own installation token rather than receiving one from
the implement job: job outputs are not secret-masked.

self-fix-pr.sh is unchanged — it already injects whatever GH_TOKEN it is
given into the clone's remote URL.

Refs #430"
```

---

### Task 3: Document what the token changes, and the manual proof

**Files:**
- Modify: `docs/PIPELINE-APP-SETUP.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the behaviour delivered by Tasks 1 and 2.
- Produces: no interface.

- [ ] **Step 1: Record the permissions inversion**

The runbook tells operators which permissions to grant. It should also say what
those permissions now govern. Append to `docs/PIPELINE-APP-SETUP.md`, before
*"If you skip this"*:

```markdown
## What the App token governs

When a workflow step uses the App token rather than `GITHUB_TOKEN`, the job's
`permissions:` block **no longer governs that call** — the App's installed
permissions do. The three granted above (contents, issues, pull requests, all
read/write) cover everything the pipeline pushes.

This inverts a reasonable expectation: narrowing a job's `permissions:` later
will not constrain the App-token calls. If you need to restrict what the
pipeline can do, change the App's permissions, not the workflow's.
```

- [ ] **Step 2: Add the changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, in the **existing** `### Fixed`
subsection — do not add a second one, `[Unreleased]` already has `Added`,
`Changed`, `Deprecated`, `Removed` and `Fixed`, and a duplicate heading trips
markdownlint MD024:

```markdown
- **pipeline:** pushes now act as the GitHub App, not `github-actions[bot]`.
  Configuring the App made pipeline *PRs* App-authored, but `actions/checkout`
  persisted `github.token`, so every push still stalled its runs at
  `action_required` — which mattered increasingly once agents began pushing
  after every task. The implement job's checkout takes the App token (and its
  mint step moved above the checkout to make that possible), and both review
  jobs now mint a token and hand it to self-fix. Consumers without the App are
  unaffected: every reference falls back to `github.token` (#430).
```

- [ ] **Step 3: Full gate**

```bash
bash tests/run-all.sh
actionlint .github/workflows/agent-implement.yml
pre-commit run --all-files
```

Expected: every runner green; `actionlint` clean; all hooks pass. Run
`pre-commit` locally rather than discovering `markdownlint` or `typos` findings
in CI.

- [ ] **Step 4: Commit**

```bash
git add docs/PIPELINE-APP-SETUP.md CHANGELOG.md
git commit -m "docs(setup): say what the App token governs

A step using the App token is bound by the App's installed permissions, not
the job's permissions: block. Worth stating, because narrowing the latter
later will not have the effect someone expects.

Refs #430"
```

- [ ] **Step 5: State the manual verification in the PR**

No unit test can prove this works; the proof is a real dispatch. Put this in the
PR description rather than pretending a test covers it:

> **Manual verification required.** Dispatch a **multi-task** issue and confirm
> the second task's push triggers checks without approval:
>
> ```bash
> gh run list --branch <branch> --json event,status,conclusion,name \
>   --jq '.[] | "\(.event) \(.status)/\(.conclusion) \(.name)"'
> ```
>
> Expect no `action_required`. Before this change, the first push's runs
> completed and every later push's runs stalled.

---

## Verification

```bash
# The consumer checkout takes the token; pipeline-ref checkouts do not
grep -n 'token: ..{ steps.app_token' .github/workflows/agent-implement.yml
grep -c 'ref: ..{ inputs.pipeline-ref' .github/workflows/agent-implement.yml   # expect: 3

# All three jobs mint, and declare the env the mint's if: depends on
grep -c 'id: app_token' .github/workflows/agent-implement.yml                      # expect: 3
grep -c 'PIPELINE_APP_ID: ..{ secrets' .github/workflows/agent-implement.yml  # expect: 3

# Both self-fix steps push with the App token
grep -n 'id: self_fix' -A 4 .github/workflows/agent-implement.yml | grep GH_TOKEN  # expect: 2, both app_token

# Ordering holds in the implement job
grep -n 'id: app_token\|name: Checkout consumer repo' .github/workflows/agent-implement.yml | head -2

# Full gate
bash tests/run-all.sh
actionlint .github/workflows/agent-implement.yml
pre-commit run --all-files
```
