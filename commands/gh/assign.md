---
description: Assign an issue to a GitHub coding agent (@claude) to implement it — Copilot disabled
argument-hint: "<issue-number> [async] — agent is claude only (Copilot disabled), monitor defaults on"
---

Hand an existing issue to a GitHub **coding agent** so it opens a PR implementing it.
`$ARGUMENTS` is `<issue-number>` plus an optional `async` token. `async` (or
`--async`) skips the post-assignment monitor — otherwise a monitor is set up by
default, see **Monitor** below.

## Agent — claude only (Copilot disabled)

**Copilot is disabled as of 2026-09-01** (GitHub Copilot access was revoked on
this account). Always assign to **claude** (`anthropic-code-agent`) — do not
resolve or assign `copilot-swe-agent`, even if explicitly requested; explain
why and stop instead. To re-enable, restore the pre-2026-09-01 version of this
section and the `case` branch below (see git history).

## Preconditions — confirm before assigning

1. The issue is **open**, **not parked** (`parked`), and not already assigned to an agent —
   `gh issue view <N> --json state,labels,assignees`. If parked or already agent-owned, stop and say so.
2. The issue is **actionable** — it has clear scope/AC. If it's `❓ to-be-defined` or
   `needs-enrichment`, warn that the agent will likely produce a weak PR, and confirm before proceeding.
3. The chosen agent is **assignable** in this repo (see the suggestedActors query below); if it
   isn't listed, the GitHub app isn't installed — say so and stop.

## Post the implementation contract

Read `~/.claude/commands/gh/implementation-contract.md` and follow it: apply its
ordered detection rule to this issue, pick **one** variant, and post that variant
as an issue comment with `<N>` replaced by the issue number from `$ARGUMENTS`.

That file is the single source of truth for both the rule and the two contract
bodies — do not restate either here.

**On a re-dispatch, check the contract is not stale before relying on it.** The
contract is a comment, and re-applying `ai-implement` does not re-post it — the
agent reads whatever comment is already there, however old. When
`implementation-contract.md` has changed since it was posted, the run silently
follows superseded instructions.

So before labelling, look for an existing contract comment on the issue:

- **None** → post the chosen variant, as above.
- **One that matches the variant you would post now** → leave it; say so and move on.
- **One that differs** → post the current variant as a new comment, opening it with
  one line naming what it supersedes and why, e.g.
  `> **Superseding the contract posted at <timestamp>.** It told you to commit but
  never to push, so a truncated run lost everything.` Do not edit or delete the old
  comment — the issue's history is how an operator reconstructs which instructions a
  given run actually followed.

This is not hypothetical. `flowhub#20` was dispatched three times against a contract
posted before the push-per-task fix landed. The third run implemented six of seven
tasks, committed each one exactly as that stale contract asked, pushed none of them,
and produced nothing — the fix had been merged hours earlier and the issue never saw it.

Before posting, print one line naming the variant chosen and the rule that selected
it, e.g. `contract: docs-only (rule 1 — AC says "no test is added or changed")`, so
the operator can correct it before the agent picks the issue up.

## Resolve the actor and assign

Bots can't be assigned via `gh issue edit --add-assignee` (it resolves logins as users).
Use the GraphQL `replaceActorsForAssignable` mutation with the bot's actor id:

```bash
n="<issue-number>"
bot="anthropic-code-agent"
owner="$(gh repo view --json owner -q .owner.login)"
name="$(gh repo view --json name -q .name)"

# Issue node id
issueId="$(gh api graphql -f owner="$owner" -f name="$name" -F n="$n" -f query='
query($owner:String!,$name:String!,$n:Int!){
  repository(owner:$owner,name:$name){ issue(number:$n){ id } } }' \
  --jq '.data.repository.issue.id')"

# Bot actor id (also proves the agent is assignable here)
botId="$(gh api graphql -f owner="$owner" -f name="$name" -f query='
query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    suggestedActors(capabilities:[CAN_BE_ASSIGNED], first:50){
      nodes{ login __typename ... on Bot{ id } ... on User{ id } } } } }' \
  --jq ".data.repository.suggestedActors.nodes[] | select(.login==\"$bot\") | .id")"
[ -z "$botId" ] && { echo "Agent '$bot' is not assignable in this repo (app not installed)."; exit 1; }

# Assign (replaceActorsForAssignable handles bot actors; replaces existing assignees)
gh api graphql -f assignableId="$issueId" -f actorId="$botId" -f query='
mutation($assignableId:ID!,$actorId:ID!){
  replaceActorsForAssignable(input:{assignableId:$assignableId, actorIds:[$actorId]}){
    assignable{ ... on Issue{ number assignees(first:10){ nodes{ login } } } } } }' \
  --jq '.data.replaceActorsForAssignable.assignable | "assigned #\(.number) → \([.assignees.nodes[].login]|join(", "))"'
```

## After

Print the issue number, the agent assigned, and the issue URL. Note that the agent works
on its **own branch** and opens a (usually draft) PR — watch for the 👀 reaction as the
signal it picked the task up. Don't merge anything.

## Monitor — default unless `async` is requested

Unless `$ARGUMENTS` includes `async`/`--async`, set up a background monitor right after
assigning and tell the operator you've done so (one line: what it's watching for). With
`async`, skip this section entirely — just report the assignment and stop; the operator
checks back themselves.

The monitor runs two phases, because there is no PR yet at assignment time:

1. **Wait for the PR to appear.** Poll the issue's timeline for a `cross-referenced` event
   pointing at a PR (or search `gh pr list --search "<N> in:body" --state open`), and/or
   watch for the 👀 reaction on the issue. This can take anywhere from a couple of minutes
   to a while — don't treat "no PR yet" after one poll as a problem.
2. **Wait for review-ready**, once the PR number is known. Poll its timeline for a
   `review_requested` event (or a terminal `state != OPEN`) as the exit condition:

   ```bash
   owner="$(gh repo view --json owner -q .owner.login)"; name="$(gh repo view --json name -q .name)"
   gh api "repos/$owner/$name/issues/<PR_NUMBER>/timeline" --paginate \
     --jq '.[] | select(.event=="review_requested") | .created_at'
   ```

   Don't gate on `isDraft == false` or the title losing a `[WIP]`/`WIP` prefix. Observed
   with `anthropic-code-agent`: it pushed its final commit and requested review while
   leaving the PR as `isDraft: true` with `[WIP]` still in the title — those are cosmetic
   leftovers of its workflow, not an in-progress indicator. A monitor gated on the draft
   flag or title text will poll forever and never fire even though the agent finished
   minutes earlier. (Only verified against `anthropic-code-agent` so far — treat the same
   behavior for `copilot-swe-agent` as unconfirmed until observed.)

Poll every 60 seconds in both phases — well within rate-limit headroom, and matches this
project's other `gh`/`fj` event-polling loops. Two dedup traps to avoid when writing the
loop: seed the baseline (e.g. the list of pre-existing PRs/timeline events) in one pass
*before* the loop starts, never inside the same pass that checks it; and never mark a
gated/pending identifier (a CI run, a not-yet-terminal state) permanently "seen" — only
identifiers that reached a genuine terminal state are safe to stop re-checking, since
things like `gh run rerun` reuse the same run ID with a new outcome.

When the monitor fires, notify the operator with the PR number and offer `/gh:review`.

The GitHub web UI's Agents tab (`https://github.com/<owner>/<repo>/agents?author=<you>`)
shows a plain "Completed Xm ago" status for the underlying agent task too — quicker
to eyeball manually than polling the API, and useful if the operator wants a manual check
without waiting on the monitor.

If there's no `gh`/repo context, say so and stop.
