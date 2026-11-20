# Use the $100 API promo credit for enrichment + model/effort evals — DRAFT

> **Status: brainstorming in progress, NOT approved.** Nothing is built. This file
> captures the conversation so far so it can be resumed after `/clear`.

## Context (facts)

- Claude Console org "freaxnx01's Individual Org" holds **$100 promo credit**,
  granted 2026-11-05, **expires 2026-12-05 (UTC)**. Plus **$9.70** purchased credit.
- Promo credit applies to: **Agent SDK, API, Batch API, Playground, Managed Agents**.
  Claude Code is *not* listed (purchased credit covers "API, Claude Code, Playground").
  → `claude --print` with an API key likely bills the $9.70, not the promo. **Untested.**
- Pipeline (`agent-implement.yml`), autopilot (`scripts/autopilot.sh`, uses
  `claude --print`) and enrichment all run on the Max subscription via
  `CLAUDE_CODE_OAUTH_TOKEN`. The credit is unused unless something is switched.
- `commands/enrich.md` "Cost rules": enrichment and pipeline share one subscription;
  the 5-hour limit was hit twice in one day (#456). Model-by-issue-size table there is
  a judgement call, not measured.
- Pricing (skill cache 2026-10-06, $/MTok in/out): Opus 5.5 4/20, Sonnet 5.5 2/10,
  Haiku 5.5 0.10/0.50. Batch API −50 %. Managed Agents session time $0.08/h.
- No `anthropic` / Agent SDK package installed on agent-dev yet (install needs approval).

## Decisions so far

- User chose option **"Enrichment + Evals"**: run the enrich lane via the **Agent SDK**
  on the promo credit, measure model + effort, **sandbox repo first**
  (`agent-action-sandbox`). Pipeline stays on the subscription.
- Scope: only this. Other findings get written down, not acted on.

## Open question (where we stopped)

User does not recall feeling the 5-hour-limit pain. Claude's guess: the **measurement
data** (which model/effort is enough for enrichment) matters more than relieving the
subscription — which would allow a smaller build (eval harness rather than a full
autopilot rewrite). **Awaiting the user's confirmation or correction.**

## Guardrails noted

- Never put `ANTHROPIC_API_KEY` into pipeline/autopilot env — it would silently move
  Claude Code billing off the subscription (`env -u ANTHROPIC_API_KEY` is used today).
- First do a tiny test call to see which balance drops and check Console rate limits.
- Nothing from `~/nas-freax` goes to the API.

## Next

1. Get the answer to the open question; continue brainstorming (goals, non-goals,
   how success is measured, eval set: which issues, which grading).
2. Write the approved design here, builder check, then `superpowers:writing-plans`.
