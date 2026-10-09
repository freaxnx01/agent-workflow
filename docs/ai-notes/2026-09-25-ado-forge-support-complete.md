# Azure DevOps forge support — complete (2026-09-25)

Closing record for the ADO work. **All five issues are closed and every PR merged**;
there is no in-flight phase. This exists so the next session can resume cold
without re-deriving the decisions.

## What exists now

Azure DevOps is a first-class forge in two halves, both verified against a live
organization rather than asserted:

| Half | Issue | What works |
|---|---|---|
| Interactive commands | **#286** | All 12 commands carry a real `## Azure DevOps` section |
| Pipeline adapter | **#253** | `scripts/lib/forge.sh`, 7 verbs, both forges |
| `/issues` correctness | **#386** | 5 defects fixed, 4 of which failed silently |
| Remote parsing | **#387** | `ssh://host:PORT/v3/…` no longer shifts every field |
| Label convention | **#397** | `🧊 parked` → `parked`, ADR-016 |

Entry point: **`scripts/implement-azdo.sh`**. Shape is
**invoke → implement → draft PR → human reviews and merges.**

## Decisions worth not re-litigating

- **A shell adapter, not a skill.** #253 proposed a skill. The logic is twelve
  env-driven shell scripts, so the seam is a function table. A skill is still the
  right wrapper later for invoking it conversationally.
- **Factory repos run Claude; product repos keep the cheap fleet default.** See
  `docs/FACTORY-MAP.md`. The measurement behind glm-5.2 (#294) still holds for
  products.
- **The parked label is plain `parked` everywhere** (ADR-016). ADO rejects emoji in
  tag names, and WIQL `CONTAINS` matches whole tags, so the old "cost" of bare-word
  matching never existed.
- **The 40 `game-*` repos are deliberately left without `actions: write`.** Sampled
  12: one has ever dispatched, once. Broken retry costs nothing there and #412
  means they self-heal on re-onboarding. **This is settled — do not sweep them.**

## Deliberately NOT done

- **The merge envelope (verb 6).** `check-merge-envelope.sh` is 23 calls of
  GitHub-specific reasoning about required checks and review decisions; ADO has
  branch policies and reviewer votes, a genuinely different model. If ADO
  review/merge is ever wanted, **open a fresh issue** — #253's premise was
  superseded and reopening it would drag the wrong framing along.
- **Re-dispatch (verb 7).** No ADO equivalent exists. That also costs
  `escalate-on-retry`. Inherent, not missing.

## The test rig — do not delete

`agent-workflow-sandbox` in the personal org `AndreasImboden0022` is the only place
ADO changes can be verified. Credentials: `direnv exec ~/repos/ado/personal …`.
Preserved fixtures, each chosen to prove something:

- Work items **1–4** — linked-PR, `parked`, `roadmap`, and a plain control
- Work item **6** — the write probe for `azdo_set_description` / the lock round
  trip (#488). Its description, tags and comments are expected to churn; the
  other four must not. (It is **6**, not 5: id 5 was not returned by a
  project-scoped WIQL and `work-item show --id 5` errors `TF401232`. The cause
  was not checked — treat work-item ids as org-scoped, and never assume the next
  one.)
- Areas `agent-workflow-sandbox` **and `empty-area`** — the empty one proves a
  present-but-empty area returns 0 rows while a *missing* one errors `TF51011`
- Iterations `Sprint 1` (nested `Week A`) and `Sprint 2` — the `--depth` trap and
  the two-step create

**Never write to the `bossinfo` org.** The PAT at `~/repos/ado/.envrc` reaches it
and it is production.

## Fallout — arguably larger than the ADO work

- **Retry was broken fleet-wide.** `actions: write` was missing from 70 of 73
  consumers, so every retry 403'd and `escalate-on-retry` had never fired anywhere.
  Now 33 repos have it (all non-`game-*`), plus the onboarding generator (#412).
- **An env-injection vulnerability**, introduced and fixed in the same session: a
  fixed `GITHUB_ENV` heredoc delimiter let a crafted issue body set arbitrary
  environment variables for the whole job.
- **`onboard-consumer.sh` produced the opposite of its documented default** —
  `--agent claude` emitted no `agent:` line, and the reusable workflow defaults to
  `opencode`.

## The lesson, if only one survives

**Seven defects in #253 alone surfaced only under real execution**, two of them
exiting `0` while doing nothing. Reading the code found none. Several "green"
checks were vacuous until run against code that should have failed them.

Treat a passing check as evidence only once you have seen it go red.

## If picking this up cold

There is **nothing outstanding on ADO**. Reasonable next moves, in no particular
order:

1. Nothing — the work is finished and verified.
2. Open a fresh issue for the ADO merge envelope, if that capability is wanted.
3. Unrelated open PRs predating this work: **#313, #327, #328, #371**.
