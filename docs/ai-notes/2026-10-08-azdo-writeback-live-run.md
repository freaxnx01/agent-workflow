# Live verification of the Azure DevOps write-back path (#488)

Run 2026-10-08 against the sandbox org `AndreasImboden0022`, project
`agent-workflow-sandbox`, sourcing **the repository's** `scripts/lib/azdo.sh`
(not the stale installed copy under `$HOME/.claude/`). Credentials via
`direnv exec ~/repos/ado/personal …`.

Functions exercised: `azdo_description`, `azdo_set_description`,
`azdo_comment`, `azdo_comments`, `azdo_add_tag`, `azdo_remove_tag`,
`azdo_fields`.

**Headline: the design holds.** `replace` on `System.Description` replaces, it
does not append. Three secondary findings below are worth more than that
confirmation, because each contradicts something the code or the brief assumed.

---

## Summary of findings

| # | Finding | Matched expectation? |
|---|---|---|
| 0 | **The write URL is org-scoped — a wrong id writes across projects** | Not anticipated at all |
| 1 | The probe work item is **6**, not 5 | **No** — the brief assumed 5 |
| 2 | `replace` on `System.Description` replaces | Yes |
| 3 | The service **rewrites the HTML**: `<p>x</p>` comes back `<p>x </p>` | **No** — undocumented |
| 4 | An emoji survives, but stored as an **HTML entity**, not a codepoint | **Partly** — see below |
| 5 | `replace` on an **absent** `System.Tags` succeeds | **No** — `azdo.sh` says it errors |
| 6 | A json-patch `test` on `/rev` **is honoured** | Yes (exploratory) |

---

## Finding 0 — the write URL is org-scoped, and nothing warns you

The single most reusable thing in this file, so it gets its own heading rather
than living inside Step 1.

```text
PATCH https://dev.azure.com/<org>/_apis/wit/workitems/<id>?api-version=7.1
                                  ^^^^^^^^^^^^^^^^^^^^^^^^
                                  no project segment, anywhere
```

Both write functions in `scripts/lib/azdo.sh` use that URL, and
`az boards work-item show --id` has the same shape. **`AZDO_PROJECT` does not
constrain the write** — it is used only by the reads (`azdo_fields`,
`azdo_comments`, `azdo_wiql`, all of which take a `project=` route parameter).

Work-item ids are allocated **per organization**, not per project. So an id that
looks like "the next one in this project" can belong to a different project, and
the PATCH will rewrite it without complaint — no error, no mismatch warning,
exit 0. There is no project check anywhere on the write path.

This run demonstrated the premise concretely: the brief predicted id 5, the
service issued 6, and 5 is not readable in this project at all. Had the brief's
hardcoded `5` been used, every step would have aimed at whatever holds id 5
org-wide. In an org that also contains production projects — this PAT reaches
`bossinfo` — that is the whole ballgame.

**Rule: never pass an id you guessed, counted on, or carried over from a plan.
Pass one you have read back from the project you intend to touch.** Every write
in this run ran behind a guard re-asserting, per invocation: the org URL is
literally the sandbox one, the id is numeric and not in 1–4, and a fresh read of
the id reports `System.TeamProject == agent-workflow-sandbox` with a title
ending `(#488)`.

Now recorded as a warning comment above `azdo_set_tags` and `azdo_set_description`.

---

## Step 1 — create the write-probe work item

```bash
az boards work-item create --org "https://dev.azure.com/AndreasImboden0022" \
  --project agent-workflow-sandbox --type Issue \
  --title "write probe — do not delete (#488)" \
  --fields "System.AreaPath=agent-workflow-sandbox\agent-workflow-sandbox" \
  --output json --only-show-errors
```

Actual:

```text
ID=6
PROJECT=agent-workflow-sandbox
TITLE=write probe — do not delete (#488)
AREA=agent-workflow-sandbox\agent-workflow-sandbox
REV=1
HAS_DESC=False
TAGS=None
```

**Did not match.** The brief predicted id `5`; the service allocated **6**. A
project-scoped WIQL immediately before the create returned ids `1,2,3,4` only,
and a read-only `az boards work-item show --id 5` against the org returns:

```text
ERROR: TF401232: Work item 5 does not exist, or you do not have permissions to read it.
```

That message does not separate "deleted" from "never existed" from "exists in
another project this PAT cannot read", and a `@project` WIQL also excludes the
recycle bin — **so the cause was not determined.** What is established is only
that 5 was unavailable and the next id was issued.

This is not cosmetic — see **Finding 0** above for why a wrong id is dangerous
rather than merely wrong, and for the guard every step below ran behind.

## Step 2 — the `add` branch, on an item with no description

```bash
azdo_description 6          # pre-read
azdo_set_description 6 "<p>first</p>"
azdo_description 6          # read back
```

Actual:

```text
pre-read   rc=0  value=[]
set        rc=0  echoed=[<p>first </p>]
read back  rc=0  value=[<p>first </p>]
```

Matched, with one unexpected detail: **the value sent was `<p>first</p>` and the
value stored is `<p>first </p>`** — the service inserted a space before the
closing tag. The pre-read correctly returned empty (exit 0, no value), so
`azdo_set_description` chose `add`, which is the branch under test.

> **Consequence for callers: never compare a description round trip with `==`.**
> Any idempotency check of the form "is the body I am about to write already
> there?" will report a difference forever if it does an exact match. Compare on
> a normalized form, or on a marker substring.

`commands/enrich.md` already prescribes exactly that ("Assert the read-back
contains the heading and both paths rather than comparing bytes"), so this
confirms an existing instruction rather than invalidating one. The rewrite was
observed on a **bare single `<p>` only**; headings, `<ul>`/`<li>`, `<code>` and
multi-element bodies were not round-tripped in isolation, so the exact scope of
the sanitizer is unknown.

The one composite case that *was* checked is the escaping round trip, below.

## Step 3 — the load-bearing experiment: does `replace` replace?

The whole write path rests on a second write overwriting the first rather than
appending — the failure mode `azdo_set_tags` exists to escape.

```bash
azdo_description 6                       # precondition: must be non-empty
azdo_set_description 6 "<p>second</p>"
azdo_description 6
```

Actual:

```text
precondition  rc=0  value=[<p>first </p>]      # non-empty -> replace branch taken
set           rc=0  echoed=[<p>second </p>]
read back     rc=0  value=[<p>second </p>]

PATCH-response: contains 'first'=False  contains 'second'=True
read-back:      contains 'first'=False  contains 'second'=True
VERDICT=REPLACED
```

**Matched. The assumption is confirmed.** Judged by substring rather than exact
match, because Step 2 established the service rewrites the markup — an exact
comparison would have failed here for a reason unrelated to the question.

Both failure modes were checked explicitly and neither occurred: `first` appears
in neither the PATCH response nor the independent read (so it did not append),
and `second` does appear in the read (so the write was not silently ignored).
The precondition guard matters — had the description been empty, the `add`
branch would have run again and the test would have proved nothing.

## Step 4a — does an emoji survive a comment?

```bash
azdo_comment 6 "🔒 Enrichment lock acquired at 2026-10-08T15:25:20Z"
azdo_comments 6 | tail -1
```

Actual:

```text
sent (ascii-repr): '\U0001f512 Enrichment lock acquired at 2026-10-08T15:25:20Z'
azdo_comment  rc=0
azdo_comments rc=0
tail -1    -> 🔒 Enrichment lock acquired at 2026-10-08T15:25:20Z

raw comments JSON, comment id 170267xx:
  raw ascii-repr: '&#128274; Enrichment lock acquired at 2026-10-08T15:25:20Z'
  U+1F512 present in raw body: False
```

**The marker survives — but only because `azdo_comments` unescapes it.** Checked
at codepoint level against the raw API response rather than by eyeballing the
terminal, so this is not a local-locale artifact.

The service does **not** store the character. It stores the HTML numeric
reference `&#128274;`, and the raw body contains no `U+1F512`. `azdo_comments`
runs `html.unescape()` over the stripped text, which restores the real character,
so the round trip through the library is faithful.

> **So the `🔒` marker in `commands/enrich.md` / `commands/enrich-phased.md` is
> safe and needs no ASCII fallback — on the strict condition that lock detection
> goes through `azdo_comments`.** A caller that greps the raw comments API, or
> any other reader that skips the unescape, will match nothing. This is a second
> independent reason the stripping/unescaping belongs in the library rather than
> at each call site.

ADR-016's finding stands unchanged and is a different constraint: it covers tag
*names*, which reject emoji outright. A comment *body* accepts them, lossily but
recoverably.

## Step 4b — tag round trip, with a preservation control

The probe had no tags at all, which makes "leaves other tags untouched"
vacuous — so a control tag was added mid-sequence rather than asserting
preservation against an empty set.

```bash
azdo_add_tag 6 enrichment-ongoing   # (i)  replace op on an ABSENT System.Tags
azdo_add_tag 6 probe-control        # (ii) second tag
azdo_remove_tag 6 enrichment-ongoing# (iii) must leave probe-control standing
```

Actual (`azdo_fields` after each):

```text
baseline  tags=""
(i)   rc=0 echoed=[enrichment-ongoing]                 tags="enrichment-ongoing"
(ii)  rc=0 echoed=[enrichment-ongoing; probe-control]  tags="enrichment-ongoing; probe-control"
(iii) rc=0 echoed=[probe-control]                      tags="probe-control"
```

Matched on behaviour: the tag appears, a second tag coexists, and removing the
first leaves the second intact. The lock tag round trip works.

**But step (i) contradicts the library's own comment.** `azdo_set_tags` sends
`{"op": "replace"}` unconditionally, and the header comment on
`azdo_set_description` states that `replace` "errors on a field that does not
exist yet" — which is the entire justification for choosing the op from a prior
read. Here `replace` was sent against a work item whose `System.Tags` key was
**absent** (not empty — `azdo_fields` defaults it, see its own comment) and it
succeeded, exit 0, tag applied.

So that claim is **not universal**. Either it is field-specific — plausibly
`System.Description` behaves differently from `System.Tags` — or it never held
and the read-then-choose logic in `azdo_set_description` is defensive rather than
required. This run did not isolate which: `azdo_set_description` correctly chose
`add` on the empty item in Step 2, so `replace`-on-absent-`System.Description`
was never sent. **Deliberately left untested and unchanged** — the read-first
logic is harmless and the caller must read anyway to compose the new body. Worth
a follow-up only if someone proposes removing it.

## Step 5 — does a json-patch `test` on `/rev` work in the same PATCH body?

Exploratory. **Explicitly out of scope — nothing was implemented on this.**

A single accepted request proves nothing, because a server that silently ignores
an unknown `test` op also returns success. So the stale case was sent first.

```bash
# (a) stale: test /rev == 6 while the item is at rev 7
# (b) current: test /rev == 7
[{"op":"test","path":"/rev","value":<rev>},
 {"op":"replace","path":"/fields/System.Description","value":"…"}]
```

Actual:

```text
current rev=7

(a) stale, value=6   REJECTED typeKey=TestPatchOperationFailedException
    message=VS403351: Test Operation for path /rev failed, value 7 was not equal to test value 6.
    description afterwards: [<p>second </p>]     <- unchanged, the replace did NOT apply

(b) current, value=7 SUCCESS rev=8 description='<p>third </p>'
    description afterwards: [<p>third </p>]
```

**The `test` op is genuinely honoured.** Stale rev rejected, the accompanying
`replace` in the same body did not apply (the whole patch is atomic), current rev
accepted. Note the response to (b) reports `rev=8`: the successful patch itself
advances the rev, so a retry loop must re-read.

This means a follow-up could give the enrichment lock real optimistic
concurrency: read `rev`, send `test /rev` alongside the lock write, and map
`TestPatchOperationFailedException` / `VS403351` to a `64+` "lost the race" exit
code. **Not implemented here** — recorded for whoever picks it up.

## Step 6 — `azdo_html_escape` round trip (not in the brief)

The brief has no step for `azdo_html_escape`, though it is on the write path for
every value `/enrich` interpolates. Checked here so it is not shipped unexercised.

```bash
RAW='a < b & "c" > d'
ESC="$(printf '%s' "$RAW" | azdo_html_escape)"
azdo_set_description 6 "<p>$ESC</p>"
azdo_description 6
```

Actual:

```text
raw      = [a < b & "c" > d]
escaped  = [a &lt; b &amp; &quot;c&quot; &gt; d]
set  rc=0  echoed=[<p>a &lt; b &amp; &quot;c&quot; &gt; d </p>]
read rc=0  value=[<p>a &lt; b &amp; &quot;c&quot; &gt; d </p>]
stripped+unescaped = 'a < b & "c" > d '
round trip faithful (ignoring the added space): True
```

Matched. The entities are stored **as entities** — neither double-encoded
(`&amp;lt;`) nor decoded back to raw `<`, either of which would have broken the
stored markup. The only mutation is the same trailing space from Step 2. So
escaping values before interpolation is both necessary and sufficient.

---

## State the probe was left in

Work item **6**: description `<p>third </p>`, tags `probe-control`, one comment
carrying the lock line, rev 8. Fixtures **1–4 were never written to** — no
description, no tag, no comment. The `bossinfo` org was never named in any
command.

One side effect worth knowing: the probe sits in the queried area path, so
`/issues`, `/queue` and `/triage` against the sandbox now return it alongside
work item 4. Rig checks that expect exactly one open plain item need updating.

## Outstanding

- **A stale sentence in `commands/enrich.md`.** Its Azure DevOps section says
  the `🔒` marker "surviving a `--discussion` write is unverified — the next task
  confirms it against a live work item; fall back to an ASCII marker such as
  `[LOCK]` if the service does not preserve it." That is this run, and the answer
  is **it survives, no fallback needed**. The sentence should be replaced with
  the entity caveat from Step 4a. **Not edited here** — out of this task's
  two-file scope.
- **`/update-commands`** (brief Step 8) has **not** been run — it is a slash
  command for the human operator. The installed copies under `$HOME/.claude/`
  remain stale until it is.
