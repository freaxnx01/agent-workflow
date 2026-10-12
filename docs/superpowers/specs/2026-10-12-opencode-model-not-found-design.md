# OpenCode "Model not found" — inject, preflight, classify — design

**Issue:** #518 (supersedes the `transient` bucketing from #439; related #376, #516, #517) · **Date:** 2026-10-12 · **Status:** approved (headless/quick)

**Lands after #521: both change scripts/classify-failure.sh; rebase on it.**

## Problem

On 2026-10-12 five opencode implement runs in game-rhyflitzer were dispatched at
once on `z-ai/glm-5.3`. One ran; four died at 0 turns / $0.00 with

```text
Model not found: openrouter/z-ai/glm-5.3. Did you mean: z-ai/glm-4-32b, z-ai/glm-4.5, z-ai/glm-4.5-air?
```

The issue guessed "the live catalog could not be loaded" and marked it unverified.

## Cause (reproduced, opencode 1.15.13 — the version `scripts/ensure-toolchain.sh:41` pins)

**It is a startup race, not a failed fetch.** opencode never waits for its model
catalog:

- The catalog is `https://models.dev/api.json` (5.4 MB), cached at
  `$XDG_CACHE_HOME/opencode/models.json` (`~/.cache/opencode/models.json`).
- At startup opencode reads that cache file; when it is absent it uses a snapshot
  compiled into the binary and refreshes the cache **in the background**. The
  1.15.13 snapshot's newest GLM ids are `z-ai/glm-5`, `-5-turbo`, `-5.1`,
  `-5v-turbo` — neither `glm-5.2` (today's fleet default, #376) nor `glm-5.3`.
- `opencode run` looks the model up as soon as the provider state is built. On a
  cold cache a newer id resolves only if the 5.4 MB download finishes first.

The model id is handed to opencode at `.github/workflows/agent-implement.yml:844-845`
(`opencode run --model "$oc_model"`) and at `scripts/lib/agent-cmd-opencode-fix.sh:35`.
Nothing before those lines warms the cache, and every consumer job runs on
`ubuntu-latest` — a fresh VM, so the cache is cold on **every** run.

Measured (dummy API key, isolated XDG dirs, no completion request left the box):

| Condition (cold cache unless noted) | `opencode run --model openrouter/z-ai/glm-5.3` |
|---|---|
| catalog host unreachable | `Model not found … glm-4-32b, glm-4.5, glm-4.5-air` — byte-identical to the incident |
| live catalog, answer immediate | resolved |
| live catalog content, answer delayed **1 s** / 3 s / 12 s | `Model not found` each time |
| warm cache containing the id | resolved |
| `opencode models openrouter --refresh` first, then run (catalog delayed 3 s) | resolved |
| **injected config entry**, catalog unreachable | **resolved** |
| **injected config entry**, catalog delayed 3 s, no warm-up | **resolved** |

The incident's own logs agree: the failing run (38267726965, `ubuntu-latest`,
"Performing one time database migration" = fresh home) built its provider state
in 175 ms and logged no `Failed to fetch models.dev`; the run that worked
(38267741471) took 292 ms. Four of five lost the race.

Two further measurements shape the design:

- An injected entry `{}` makes opencode accept **any** id, typos included
  (`z-ai/glm-5.33-typo` is listed). So once ids are injected, opencode's own
  resolver can no longer tell "new model" from "wrong model".
- An injected `{}` alone carries no metadata: with the catalog missing the model
  reports cost 0 and context limit 0. With the catalog loaded the same entry
  keeps the catalog's values (cost 0.079 / 4.8, context 1,048,576).

## Design

### 1. Inject the model entry (resolution)

New `scripts/opencode-model-config.sh`: reads `MODEL`, strips a leading
`openrouter/`, prints

```json
{"provider":{"openrouter":{"models":{"<id>":{}}}}}
```

Both call sites export it as `OPENCODE_CONFIG_CONTENT` for the `opencode`
process: the `Run OpenCode` step and `scripts/lib/agent-cmd-opencode-fix.sh`
(the self-fix path uses the same model and has the same race). No file is
written into the checkout, so the agent cannot commit it.

### 2. Warm the catalog (metadata)

Before `opencode run`, the `Run OpenCode` step runs
`timeout 60 opencode models openrouter --refresh >/dev/null 2>&1 || true`.
`--refresh` is the one invocation that waits for the catalog (plain
`opencode models` does not — measured). It is best-effort: it exists so cost and
context limits are real when models.dev is reachable; injection (§1) is what
makes the run start when it is not.

### 3. Preflight: does OpenRouter list the id? (`model_not_found`)

New `scripts/check-opencode-model.sh`, same shape as
`scripts/check-opencode-auth.sh`. It fetches OpenRouter's public model list
(`GET https://openrouter.ai/api/v1/models`, no credential, not a completion) and
looks for `MODEL` in `.data[].id`.

- Listed → exit 0.
- An id with a `:suffix` that is not listed itself is accepted when its base id
  is listed (`:nitro`, `:floor`, `:online` are routing shortcuts OpenRouter does
  not list; `:free` variants are listed as their own ids).
- Fetch fails or the body is not `{data:[…]}` → retry once, then **proceed**
  with a `::warning::` (fail open). A model-list outage must not stop runs that
  injection lets start.
- Not listed → write an opencode `error` event to `OUTPUT_FILE`
  (`error.name` = `ModelNotFoundError`, message starts `Model not found:`,
  names the id and the fix), print `::error::`, exit 65. The workflow step
  short-circuits exactly as it does for the auth preflight
  (`agent-implement.yml:814-818`): the adapter, classifier and run report run on
  the synthesized event; opencode is never started.

### 4. Classify: `model_not_found`

`scripts/classify-failure.sh` gets a class `model_not_found`:
`num_turns == 0` and `.result` matches `model not found|ProviderModelNotFoundError`.
It replaces the #439 branch that classed the same text `transient`
(`classify-failure.sh:81-88`). It is matched **before** `rate_limit`, `api_auth`
and `transient`: those match bare digit runs (`"?429"?`, `"?5[0-9]{2}"?`) and the
message carries the model id — `mistralai/mistral-small-2503` contains `503`.
It stays after `out_of_credits`.

The class covers both the preflight's event and opencode's own error, should it
still occur (a consumer pinned to an older pipeline ref, or a future opencode
that ignores the injected entry).

### 5. Outcome: alert only, not an attempt, no escalation

- `scripts/retry-dispatch.sh`: `model_not_found` → `stop`. No retry means
  escalate-on-retry never moves the issue to Claude.
- `scripts/post-run-report.sh`: outcome `failed: model_not_found`, `ai:failed`,
  plus a block naming the model and the fix (correct `default-model` or the
  `model:` label; ids at <https://openrouter.ai/models>; re-dispatch). The
  heading stays `## ai-implement run`. The run has 0 turns and $0.00, so
  `check-attempt-cap.sh:99-110` already counts it as a non-start, not an attempt.
- `agent-implement.yml`: a step after `Classify failure` sends one ntfy push
  (`scripts/notify-ntfy.sh`, priority `high`) when the class is
  `model_not_found`. It is not a pause reason: no alarm issue, no dispatch gate,
  other issues keep running.

### 6. Stale references

#517 left three notes saying #518 would add a pause reason
(`scripts/lib/pause-reasons.sh:16-17`, `agent-implement.yml:955-957`, and the
`failure-class` output description at `agent-implement.yml:327`). They are
corrected. `docs/CONSUMER-SETUP.md`'s troubleshooting note (§3, the #439
paragraph) is rewritten and gains "Adding a new OpenRouter model".

## Out of scope

- Bumping the pinned opencode version (#376). Injection makes the pin's snapshot
  age irrelevant for resolution.
- The review path. The workflow reviews through `scripts/lib/agent-cmd-claude.sh`;
  the ad-hoc opencode fallback in `scripts/review-pr.sh:342-345` is not a
  pipeline path and is left alone.

## Assumptions

- **A1** [confirmed] "How should a newer OpenRouter model id be made to resolve
  on every run?" → "Inject model config: the pipeline writes an opencode
  provider/model config entry for the chosen id before each run, so resolution
  no longer depends on the catalog at all. Deterministic, and adding a new model
  needs no pipeline change."
- **A2** [confirmed] "A run stops in preflight with `model_not_found`. Besides
  not counting as an attempt, what happens to the repo?" → "Alert only: that
  issue's run fails with a comment naming the model and the fix, plus one ntfy
  push; other dispatches continue." So `model_not_found` is not a pause reason,
  does not count as an attempt, and does not escalate to Claude.
- **A3** [med] The preflight asks OpenRouter's public model list whether the id
  exists. Rejected: `opencode models openrouter | grep -x <model>`, which the
  issue suggests. Under A1 that check cannot fail — an injected entry makes
  opencode list any id, a typo included (measured) — and without injection it
  would reject every model newer than models.dev knows.
- **A4** [med] The preflight fails open: if the model list cannot be fetched
  after one retry, the run proceeds. Rejected: failing closed, which would turn
  an OpenRouter listing outage into a fleet-wide stop for runs that would work.
- **A5** [med] The catalog is warmed with `opencode models openrouter --refresh`
  before every run, in addition to injection. Rejected: injection alone. It is
  enough to start the run, but whenever the race is lost the model has cost 0
  and context limit 0 (measured), so the run report and `/ai-stats` would show
  $0.00 for real spend.
- **A6** [med] A `model_not_found` run keeps the `## ai-implement run` heading
  and gets `ai:failed`; "not an attempt" comes from the existing non-start rule
  (`scripts/check-attempt-cap.sh:99-110`). Rejected: a separate heading excluded
  from both counters, like #517's `## ai-implement paused`
  (`scripts/post-run-report.sh:311-315`). That would leave a wrong
  `default-model` re-dispatchable forever; as a non-start it parks after
  `MAX_NON_STARTS` (5).
- **A7** [med] An unlisted id with a `:suffix` passes when its base id is listed.
  Rejected: exact match only, which would block `…:nitro` / `…:floor` ids that
  OpenRouter accepts but does not list.
- **A8** [high] The entry is injected through the `OPENCODE_CONFIG_CONTENT`
  environment variable. Rejected: writing `opencode.json` into the checkout (the
  agent could commit it) or a file via `OPENCODE_CONFIG`. Verified on 1.15.13.
- **A9** [high] The injected entry is `{}` — no cost or limits. A1 requires that
  a new model needs no pipeline change, so the pipeline cannot carry per-model
  metadata; A5 supplies it from the catalog.
- **A10** [high] The self-fix wrapper injects too
  (`scripts/lib/agent-cmd-opencode-fix.sh:35` hands the same model to opencode).
  It does not repeat the preflight: the implement run already passed it.
- **A11** [high] One ntfy push per failing run, with no de-duplication. A2 says
  "plus one ntfy push"; a wrong `default-model` with five dispatches is five
  pushes.
- **A12** [high] `failure-class` gains the value `model_not_found`. Additive, as
  `out_of_credits` was in #517; no consumer input changes.

## Consequences

- Every opencode run makes two more HTTPS requests before the agent starts: the
  OpenRouter model list (about 0.8 MB) and the models.dev catalog (5.4 MB,
  bounded at 60 s).
- A 0-turn `Model not found` is no longer retried or escalated to Claude (#439).
  With injection the catalog miss it covered cannot occur; what remains is a
  wrong id, which a retry cannot fix.
- If the model list is unreachable *and* the id is wrong, the run starts and
  fails on OpenRouter's own error for an unknown model. That text is not
  matched here, so it lands in whichever class its wording selects.
- Five non-starts park the issue with `check-attempt-cap.sh`'s existing text,
  which lists credentials first and does not mention a wrong model id. The run
  reports above it name the model and the fix.
- When models.dev is unreachable the run still starts, but reports $0.00 and
  opencode cannot see the model's context limit.
- A truncated `models.json` makes opencode 1.15.13 die with
  `JSON Parse error: Unterminated string` and only the generic "Unexpected
  server error" on stdout (measured). Not seen in the field — runners start
  with no cache — and not handled here.
