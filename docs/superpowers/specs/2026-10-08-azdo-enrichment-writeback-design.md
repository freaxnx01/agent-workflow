# Azure DevOps enrichment write-back — Design

**Issue:** #488 · **Date:** 2026-10-08 · **Status:** approved

`/enrich`, `/enrich-phased` and `/work` read an Azure DevOps work item fine and
write nothing back. For `/enrich` the write *is* the command. This design makes
the write possible, and records where it deliberately diverges from the GitHub
path.

## Why now

`commands/enrich.md` blamed the gap on a missing `azdo_set_tags` "built on a
json-patch `replace` rather than `--fields`", tracked as #286 Task 6. That
function shipped in `fed9fff` and lives at `scripts/lib/azdo.sh:231`; #286 is
closed. PR #489 corrected the stale text. What remains genuinely unproven is
writing `System.Description`.

## The decisive fact

Read live from `AndreasImboden0022` on 2026-10-08:

| Field | Type | Read-only |
|---|---|---|
| `System.Description` | **html** | false |
| `System.History` | history | false |
| `System.Tags` | plainText | false |

`System.Description` is an **HTML** field. GitHub issue bodies are Markdown, and
`/enrich`'s GitHub path inlines the implementation plan into the body verbatim.
That contract cannot carry over unchanged: there is no `markdown` module, no
`pandoc`, and the organization exposes no Markdown-format field.

## Decisions

### D1 — The description carries acceptance criteria and pointers, not the plan

The work item gets: the original description, then an `Acceptance Criteria`
list, then the committed spec and plan paths.

**This breaks `/enrich`'s "the implementing agent works from the body alone"
rule, on purpose.** That rule exists because the GitHub pipeline agent reads
*only* the issue body. agent-workflow's pipeline is implemented as GitHub
Actions workflows with no Azure DevOps equivalent (ADR-017), so on this forge
the reader is a human or a local `/work` session — both of which have the
repository checked out. Inlining a 40 KB plan into an HTML field would solve a
problem this forge does not have, and would render as an unformatted wall.

Rejected: wrapping the raw Markdown in `<pre>` (preserves the GitHub contract,
but produces an unusable work item); converting Markdown to HTML (requires a
dependency the guardrails forbid adding unasked, and makes the write lossy).

**This divergence gets its own ADR**, beside 012 and 016, so a later reader does
not "fix" it back.

### D2 — The lock mirrors GitHub: a tag plus a timestamped comment

`enrichment-ongoing` set through `azdo_set_tags`, plus a timestamped discussion
comment that gives the lock its age.

Both halves are needed. `/enrich` Step 1.5 treats a lock whose age it cannot
determine as **stale** and offers a takeover, so a tag without a matching
comment would be a lock that never locks.

Rejected: tag only (see above); no lock at all (leaves `/enrich-phased`
permanently unavailable, since its phases depend on a lock surviving a
`/clear`).

### D3 — An enriched work item carries no extra ready signal

The updated description *is* the signal: it has acceptance criteria and plan
paths, and an un-enriched item has neither.

This matches the ADO section of `/new`, which deliberately does not apply
`needs-enrichment` because nothing on this forge acts on it. Rejected: a `ready`
tag (new vocabulary every ADO-aware command must learn, and it can drift from
the description it claims to describe); advancing `System.State` (state names
are process-template-specific — `azdo_closed_states`' own comment warns that a
fixed list of state names is wrong somewhere, always).

## Architecture

Three functions added to `scripts/lib/azdo.sh`, following `azdo_set_tags`:
json-patch over `curl` against `api-version=7.1`, sourced not executed, no side
effects at source time, exit codes as API.

### `azdo_set_description <id> <html>`

PATCH `/fields/System.Description`.

**The json-patch op is chosen from the read, not fixed.** `replace` when the
field is already present, `add` when it is absent.

A fixed `add` was the first choice, on the assumption that `add` is upsert for
work-item fields. The repository contradicts it: `tests/run-azdo-lib-tests.sh`
records that a json-patch `add` on `System.Tags` **appends**, which is the
behaviour `replace` exists to escape. If that also holds for an HTML field, a
fixed `add` would append to the existing description — the exact mangling this
design avoids. A fixed `replace` fails on an item that never had one.

Reading first settles both cases, and the read has to happen anyway to compose
the new body. The live probe records which way `replace` actually behaves.

### `azdo_comment <id> <text>`

Posts to the work item's discussion through
`az boards work-item update --id <id> --discussion <text>` (confirmed present in
az 2.87.0 / azure-devops 1.0.4). No raw API call needed for the write.

### `azdo_comments <id>`

Reads the discussion back for the lock scan. The comments API returns bodies as
**HTML**, so this strips tags before the caller pattern-matches the lock line.

## Safety: every write is a read-modify-write

Both `System.Tags` and `System.Description` are replaced wholesale, so acquiring
a lock means read-then-append and releasing means read-then-remove.

**An empty read is not distinguishable from a failed one.** `azdo_fields`
defaults an absent `System.Tags` to `""` by design. So:

- Capture the exit status of every read and **abort on non-zero**. Never compose
  a write from a failed read.
- A failed read during *release* would otherwise wipe `parked` / `roadmap` off
  the item; during *description write* it would wipe the original description,
  recoverable only from the item's revision history.

This is the same hazard the Forgejo label path already guards in
`commands/enrich.md`, and the guard is modelled on it.

**Optimistic concurrency.** Verify live whether a json-patch `test` on `/rev`
can ride in the same PATCH body. If it can, acquiring the lock becomes atomic
against a concurrent human edit, and "lost the race" earns its own `64+` exit
code per the library's exit-codes-are-API rule. If it cannot, say so in the
function's comment rather than leaving the reader to wonder.

## HTML details

- **Escape everything interpolated** — acceptance-criteria lines and paths go
  through `html.escape` (standard library, no new dependency).
- **Absolute repo URLs**, not relative links: a relative path inside a work-item
  description resolves to nothing. Use
  `https://dev.azure.com/<org>/<project>/_git/<repo>?path=/docs/...`, or bare
  `<code>` paths where a link adds nothing.
- **Read-back asserts markers, not bytes.** ADO sanitizes stored HTML, so
  byte-equality fails spuriously. Assert the `Acceptance Criteria` heading and
  both paths are present.
- **Emoji in a comment body is unverified.** ADR-016 covers emoji in tag *names*
  only. Check whether a lock marker survives a `--discussion` write; fall back
  to an ASCII marker if it does not.
- **Same-second lock tie:** lowest comment id wins, matching the Forgejo rule.

## Command changes

- **`/enrich`** — the ADO section becomes a real write path: acquire the lock,
  spec and plan as today, then write the description and release the lock.
- **`/enrich-phased`** — becomes available on ADO. Its phases depend on the lock
  surviving a `/clear`, which now works.
- **`/work`** — **documentation only.** Its gap is pipeline dispatch, inherent to
  the forge per ADR-017, not the description write. One corrected sentence; no
  new capability.

## Testing

### Layer 1 — fixture tests, dispatchable

Extend `tests/run-azdo-lib-tests.sh` with mocked `az` and `curl` covering: the
`add` payload shape, HTML escaping, the abort-on-failed-read guard for both tag
and description writes, tag append and removal, and comment HTML stripping. No
network, under five seconds, per the CI stack overlay.

### Live verification — local only

**This repository has no Azure DevOps credential in CI.** `gh secret list` shows
none, and nothing under `.github/workflows/` references Azure DevOps. A pipeline
agent asked to "verify against the sandbox" would exercise the mocks and report
green — precisely the failure mode
`docs/ai-notes/2026-09-25-ado-forge-support-complete.md` warns about.

So any task requiring a live run is **local-only** and must be labelled as such
in the plan. Credentials: `direnv exec ~/repos/ado/personal …`.

**Use a dedicated write-probe work item.** Sandbox fixtures 1–4 each prove
something specific (linked-PR, `parked`, `roadmap`, plain control); a lock tag or
a description on any of them corrupts the rig. Create work item **#5** once, keep
it, and add it to the do-not-delete list in the ADO record.

**Never write to the `bossinfo` organization.** The PAT reaches it and it is
production.

**Live runs source the repository's `scripts/lib/azdo.sh`**, not
`$HOME/.claude/scripts/lib/azdo.sh` — the installed copy is stale during
development. Running `/update-commands` after the merge is part of delivery.

## Acceptance criteria

- [ ] `azdo_set_description` writes `System.Description` and a read-back shows
      the acceptance-criteria heading and both document paths.
- [ ] A write composed from a failed read is refused, for tags and description
      alike, proven by a fixture that makes the read fail.
- [ ] `azdo_comment` posts a timestamped lock line and `azdo_comments` reads it
      back with HTML stripped, so `/enrich` Step 1.5 can age it.
- [ ] The lock can be **released**: acquiring then releasing leaves the item's
      other tags untouched.
- [ ] Interpolated text is HTML-escaped; a title containing `<` and `&` survives
      a round trip.
- [ ] `/enrich` and `/enrich-phased` ADO sections describe the write path, and
      `/work`'s corrected sentence no longer implies a missing prerequisite.
- [ ] An ADR records the AC-plus-pointers divergence and its ADR-012 reason.
- [ ] `tests/run-azdo-lib-tests.sh` and `tests/run-script-tests.sh` both pass.
- [ ] Live verification ran locally against sandbox work item #5, and the run is
      recorded under `docs/ai-notes/`.
- [ ] `/update-commands` re-installed the commands after merge.

## Out of scope

No `ai-implement` equivalent for ADO, no ready tag, no state transition, no
Markdown-to-HTML conversion, and no change to the merge envelope or re-dispatch
— both remain inherent gaps per the ADO record.
