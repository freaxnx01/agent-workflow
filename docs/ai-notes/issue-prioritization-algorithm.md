# Handover — Issue Prioritization Algorithm

**Purpose of this document:** Hand off to a Claude Code CLI session the design of an
issue-prioritization algorithm, so it can implement a scoring script that ranks a backlog
across **GitHub (GH)** and **Azure DevOps (ADO)**.

**Status:** Design agreed. Implementation not started.
**Date:** 2026-07-20

---

## 1. Goal

Produce a single, deterministic ranked ordering of issues pulled from GH and ADO, driven by:

- **Bugs/Fixes first** (base rule)
- **Quick-Wins** — small issues with high effect (base rule)
- **Customer delivery dates** where they exist
- **Efficiency** (value per unit effort), with the Pareto principle used as a calibration
  check on the *output*, not as a scoring input.

---

## 2. Per-issue inputs to maintain

These are the only values a human maintains per issue; everything else is computed.

| Input | Meaning | Scale / values |
|---|---|---|
| `category` | Bug vs feature vs nice-to-have | tier0 / tier1 / tier2 / tier3 (see §3) |
| `impact` | Value / pain reduction if done | 1–10 |
| `confidence` | Certainty in the impact estimate | 1–10 (or 0–1) |
| `effort` | Estimated work | real units — story points or ideal days |
| `due_date` | Customer / target delivery date | date, optional |
| `commitment` | How binding the date is | contractual / committed / target |

---

## 3. The ordering pipeline (checks, in order)

Applied top to bottom. Each stage refines or overrides the previous one.

1. **Hard override — at-risk contractual check.**
   If `commitment == contractual` AND `slack <= 0` → force to absolute top, ignore score.

2. **Bugs/Fixes-first check (category tier).** Base rule #1.
   - Tier 0: critical / security / broken core
   - Tier 1: **bugs & fixes**
   - Tier 2: features & improvements
   - Tier 3: nice-to-haves / cosmetic

   Higher tier always outranks lower tier (default behaviour).

3. **Quick-Win check.** Base rule #2.
   Flag issue where `impact >= 7` AND `effort <= 3`.
   Usage — pick one (OPEN DECISION, see §6):
   - (a) highlight only, or
   - (b) allow a flagged quick-win to leapfrog low-value items in the tier above.

4. **Value/effort score (ICE ratio).**
   `ice = impact * confidence / effort`
   Ranks issues within a tier; also reinforces quick-wins (they maximize the ratio).

5. **Slack-based urgency multiplier.**
   `slack = days_until_due - estimated_work_days`
   Map slack → urgency factor:

   | slack | urgency |
   |---|---|
   | no due date | 1.0 |
   | > 15 days | 1.0 |
   | 6–15 days | 1.5 |
   | 1–5 days | 2.5 |
   | <= 0 (at risk) | 4.0+ |

6. **Commitment weight.**
   contractual ×1.5, committed ×1.2, target ×1.0.

7. **Sort & concatenate.** Sort by final score within each tier, then stack tiers.

8. **Pareto gut-check (on output, not a score).**
   Inspect top ~20%: do they hold most of the value? If the top looks trivial, recalibrate
   `impact`. Also the justification for deferring the bottom 80%.

### Final score formula (normal issue)

```text
score = (impact * confidence / effort) * urgency(slack) * commitment_weight
```

Evaluated inside the issue's `category` tier, with the step-1 override able to beat everything.

---

## 4. Field mapping per platform

Keep the same three conceptual fields — **due date, effort, commitment** — in both systems so
one formula works across both.

### Azure DevOps (ADO)

- **Due date:** native `Microsoft.VSTS.Scheduling.TargetDate` / `DueDate`. If the work item
  type lacks it, add a DateTime field via Process customization
  (Org Settings → Process → work item type → add field).
- **Effort:** native — `Story Points`, `Effort`, or `Original Estimate`.
- **Commitment:** custom picklist field `Commitment` (Contractual/Committed/Target), or a tag
  `commit:contractual`.
- **Read via:** WIQL query + REST API.

### GitHub (GH)

GitHub Issues have **no native due date**. Use, best first:

- **GitHub Projects (v2) custom fields (recommended):** a Date field "Due date", a Number field
  "Effort", a single-select "Commitment". Query via GraphQL API.
- **Milestones:** milestone `due_on` — only clean if one deliverable = one milestone.
- **Label fallback:** `due:YYYY-MM-DD` label — queryable but hand-parsed, stopgap only.
- **Read via:** GraphQL API (Projects v2 items + field values).

> Caveat: platform UIs drift — verify exact field names in your own ADO process and GH Project
> field editor before hardcoding.

---

## 5. Suggested implementation

Normalize each source into a common record:

```text
{ id, source, title, category, impact, confidence, effort, due_date, commitment }
```

Then:

1. Fetch — ADO REST API + GH GraphQL API.
2. Normalize into the record above.
3. Compute `slack`, `urgency`, `ice`, `score`.
4. Apply tiering + step-1 override.
5. Emit ranked list (CSV / Markdown table / console).

Language open — Python is a reasonable default (good HTTP + both platform SDKs).

---

## 6. Open decisions for implementer / user

1. **Quick-Win vs Bugs-first interaction (§3 step 3):** may a strong quick-win *feature*
   leapfrog a low-value *bug*? Strict tiers say no; the quick-win boost says yes. Default
   assumed: **strict tiers (bugs always win)** unless told otherwise.
2. **Tiered vs weighted model:** current design uses hard category tiers. Alternative is a
   single weighted score (WSJF-style) that avoids bug-starvation but loosens "bugs first".
3. **Urgency curve numbers** in §3 step 5 are starting values — tune to taste.
4. **Confidence scale** — 1–10 vs 0–1 (affects whether it dampens or scales the score).

---

## 7. Context / rationale (for continuity)

- **Pareto principle** was considered as a scoring input and rejected as such — there is no
  per-issue "Pareto score". Its effect (surfacing the vital few) is already produced by the
  ICE value/effort ratio. It is retained only as an output-calibration lens (§3 step 8).
- **ICE** was chosen in the ratio form `impact * confidence / effort` rather than the classic
  `impact * confidence * ease`, because estimating real Effort is easier and more honest than
  a 1–10 "Ease", and the ratio form sharply rewards quick-wins. This is effectively RICE minus
  the Reach term.
- **Slack** = buffer before deadline = `days_until_due - estimated_work_days`. Negative slack
  = cannot finish on time if started now = escalate. Chosen over raw due-date sorting because
  it combines deadline proximity *and* remaining work.
