# Make pipeline pushes act as the App

**Issue:** [#430](https://github.com/freaxnx01/agent-workflow/issues/430)
**Follows:** [#364](https://github.com/freaxnx01/agent-workflow/issues/364), which made pipeline *PRs* App-authored
**Date:** 2026-09-27
**Status:** Approved

## Problem

Configuring the GitHub App made pipeline **PRs** App-authored, so the
`pull_request` event triggers required checks. It did not make pipeline
**pushes** App-authored. Every `git push` the pipeline makes still
authenticates as `github-actions[bot]`, and the runs those pushes trigger stall
at `action_required` exactly as before.

Observed on PR #424: opened by `app/freaxnx01-pipeline` at `14:36` with checks
running; the runs that stalled were created at `14:47` and report
`actor=github-actions[bot]` for `lint`, `gate-selftest` and
`agent-implement-test`. The PR now shows `checks: 0`.

### Why it matters more since #398

Before the implementation contract reached agents, a run typically pushed once.
Now agents push after every task, so a multi-task run opens its PR as the App —
checks run — and then stalls on **every subsequent push**. PR #416 passed only
because its plan had a single task. The App therefore looks like it works, and
does, for exactly the narrow case that has been tested.

## Two mechanisms, not one

The two places the pipeline pushes get their credentials differently, and the
fix differs accordingly. Conflating them is the main way this change can go
wrong.

| | How it pushes | What it needs |
|---|---|---|
| **implement** job | The agent runs `git push` inside the checked-out repo, using credentials `actions/checkout` persisted (`persist-credentials: true` by default) | `token:` on the checkout |
| **review / self-fix** jobs | `self-fix-pr.sh` clones fresh and injects `$GH_TOKEN` into the remote URL itself (`:114-115`) | a better `GH_TOKEN` on the step |

`self-fix-pr.sh` needs **no change**. It already does the right thing with
whatever token it is handed; it is simply handed `${{ github.token }}` today
(`agent-implement.yml:1224`).

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | Only the two operations that **push** act as the App | Routing every `gh` call through it. Much larger diff across every `env:` block, and it makes the App a single point of failure for labels, comments and merges that work fine today |
| D2 | Mint an installation token **in each job that needs one** | Minting once and passing it via a job output. **Job outputs are not secret-masked**, so the token would appear in plaintext in the workflow's output data and in the logs of anything consuming it. Installation tokens are short-lived and scoped; per-job minting is the correct shape, not a workaround |
| D3 | The implement job's mint moves **above** its consumer checkout | Leaving the order and finding another way to reach the token. `actions/create-github-app-token` needs no working copy, so the reorder is free |
| D4 | The review jobs' consumer checkout is left alone | Adding `token:` there too. That checkout exists only so `check-merge-envelope.sh` can read `.claude-auto-merge-blocklist` — it never pushes |

## Design

### Component 1 — the implement job

Reorder, then wire:

```yaml
      - name: Mint pipeline App token (optional)      # moved up
      - name: Warn when no pipeline App token is configured   # moves with it
      - name: Checkout consumer repo
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
        with:
          # The agent pushes with the credentials this step persists. Without a
          # token here those pushes are github-actions[bot], and the runs they
          # trigger stall at action_required even though the PR itself is
          # App-authored (#430).
          token: ${{ steps.app_token.outputs.token || github.token }}
```

The warn step moves with the mint so the "no App token" warning still lands at
second zero, before any agent cost is incurred.

### Component 2 — the review and self-fix jobs

Both `ai_review_human_merge` and `ai_review_ai_merge` gain a mint step, and the
self-fix step's token changes:

```yaml
          GH_TOKEN: ${{ steps.app_token.outputs.token || github.token }}
```

Each job also needs its own job-level `env: PIPELINE_APP_ID` declaration.
Verified: only `implement` declares it today (`:410`). The mint's `if:` tests
`env.PIPELINE_APP_ID` rather than the secret directly because **the `secrets`
context is not available in `if:`** — so without that `env:` line the mint's
condition silently evaluates empty and the step never runs, in a way that looks
like the App simply is not configured.

Nothing else in those jobs changes. Labels, comments, run reports and the
auto-merge keep `github.token` per D1.

### Component 3 — the fallback is what makes this safe to merge early

Every change is `${{ steps.app_token.outputs.token || github.token }}`. A
consumer without `PIPELINE_APP_ID` mints nothing, falls back, and behaves
exactly as today.

**This is a no-op for the 72 consumer repos until each is wired**, so it can
merge before the rollout rather than after it.

### A behaviour that changes quietly

When a call uses an App token, the job's `permissions:` block no longer governs
it — **the App's installed permissions do**. The pipeline App holds `contents`,
`issues` and `pull-requests` read/write, which covers everything being pushed.

Recorded because it inverts an expectation: narrowing a job's `permissions:`
later will not constrain the App-token calls, and someone will eventually
assume it does.

## Testing

This is workflow YAML. The honest coverage is Layer-0 plus structural
assertions, following the precedent set by the `npm`-removal guards in
`tests/run-script-tests.sh`.

| Assertion | Why |
|---|---|
| Every **consumer-repo** checkout passes a `token:` | the fix itself |
| The three **`pipeline-ref`** checkouts do **not** | they fetch agent-workflow; scoping the change |
| `app_token` is minted in all three jobs | the review jobs have none today |
| In each job, the mint precedes any checkout consuming it | the D3 ordering bug, pinned |
| No step that pushes carries `GH_TOKEN: ${{ github.token }}` | catches a half-applied fix |
| `actionlint` clean | YAML validity |

Assertions strip YAML comments before matching, as the existing workflow guards
do — the steps explain *why* the token is needed, and matching the whole file
would count the explanation.

**Manual verification, stated not faked:** a multi-task dispatch where the
second task's push triggers checks without approval. No unit test can prove
this; pretending otherwise would be worse than naming it.

## Acceptance criteria

- [ ] A push made by the pipeline after the PR is opened triggers checks without
      manual approval when the App is configured
- [ ] A multi-task run's second and later task pushes do not stall at
      `action_required`
- [ ] Self-fix pushes are App-authored
- [ ] With no App configured, behaviour is unchanged (`github.token` fallback)
- [ ] The `pipeline-ref` checkouts continue to use the default token
- [ ] The mint step precedes every checkout that consumes its output
- [ ] `actionlint` clean; full Layer-1 suite green

## Out of scope

- Routing labels, comments, run reports or the auto-merge through the App (D1).
- `self-fix-pr.sh` — it already injects whatever `GH_TOKEN` it is given.
- The 72 consumer repos' own wiring. They need their two secrets and two
  `agent.yml` lines regardless; this is about what the reusable workflow does
  with them once present.
