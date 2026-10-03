# Keep consumer permissions in step with the workflows they call

**Issue:** [#433](https://github.com/freaxnx01/agent-workflow/issues/433) (duplicate [#434](https://github.com/freaxnx01/agent-workflow/issues/434) closed)
**Third instance of:** [#421](https://github.com/freaxnx01/agent-workflow/issues/421)'s fallout, after [#34](https://github.com/freaxnx01/agent-workflow/issues/34) and [#435](https://github.com/freaxnx01/agent-workflow/issues/435)
**Date:** 2026-10-03
**Status:** Approved

## Problem

A reusable workflow cannot be granted more than its caller. When the callee's
jobs widen, every caller that does not widen with it is **rejected at workflow
load**: `startup_failure`, zero jobs, no logs, and a check that looks like an
ordinary failure.

#421 added `actions: write` to `agent-implement.yml`'s `implement` job on
2026-09-24. Since then the same omission has been found three times:

| Caller | Found | Cost |
|---|---|---|
| `agent-implement.test.yml` | #435 | the Layer-2 guard ran no assertions for four days |
| consumer repos | #433 / #434 | `game-kit-racer` 11 consecutive failures; `game-sky-fury` 2 |

#34 fixed this class once already. It has recurred because the required
permission set is written out in several places and nothing checks they agree.

### The issue's stated premise is already false

#433 and #434 both ask for `actions: write` to be added to the consumer
template. **It was added on 2026-09-23 16:41** in `58dc477` —
`docs/CONSUMER-SETUP.md:159` and `scripts/onboard-consumer.sh:353` — four days
before either issue was filed. Both were written from a stale read.

What remains is the drift already in the fleet, and the absence of anything
preventing the next one.

### Measured exposure

A scan of 29 of the 72 consumers found **7 missing `actions: write`**, including
`game-rockfall` and `game-plod`, neither dispatched since. The scan is
alphabetical and was cut short, so the true figure across 72 is likely 15–20.
Each will `startup_failure` on its next `ai-implement` dispatch.

## Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| D1 | A Layer-1 test asserts each **caller/callee pair** agrees | Comparing every stub to one union — wrong, see *Two pairs* below |
| D2 | The sweep is a `--fix-permissions` mode on `migrate-consumers.sh` | A throwaway script. The repo already carries a scar from exactly that: the v1→v2 migration of 70 repos was done with one, and it mangled the repo pinned to a full version |
| D3 | The filter **adds missing keys only, never removes** | Making the stub match the union exactly. A consumer granting more may need it for its own jobs; this tool has no business narrowing that |
| D4 | Dry-run by default, `--apply` to write | Applying on first invocation. A fleet-wide permission rewrite should not be reachable by accident |
| D5 | No in-workflow pre-check | The issue proposes one. It cannot exist — see *Why the pipeline cannot check itself* |

## Why the pipeline cannot check itself

#433's third bullet suggests `/gh:implement` or the workflow pre-check the
caller's permissions. From inside the workflow this is **impossible**: the
rejection happens when GitHub loads the workflow, before any job or step runs.
There is nothing to run the check in.

The repo already records this, in `agent-implement.test.yml`'s own comment:

> a caller granting less than the callee requests causes GitHub to reject the
> workflow **at load** (silent startup_failure, root cause of #34).

So any guard must live outside the run. This spec puts it in Layer-1, where it
costs milliseconds and cannot itself fail to start.

## Two pairs, not one union

`onboard-consumer.sh` emits **two** stubs, and they are not copies:

| Stub | Calls | Required union |
|---|---|---|
| `agent.yml` (`:349`) | `agent-implement.yml` | `contents: write, pull-requests: write, issues: write, actions: write` |
| chain stub (`:374`) | `chain-dispatch.yml` | `issues: read, pull-requests: read, actions: write` |

Verified: the chain pair is **currently in sync**. A guard that compared both
stubs to the `agent-implement` union would fail on a correct file and teach
whoever hit it that the guard is noise.

The test must therefore be **pair-aware**: each caller is checked against the
callee it actually calls.

## Design

### Component 1 — the parity guard (Layer-1)

A new section in `tests/run-script-tests.sh` asserting, for each pair:

```
union(callee.jobs[].permissions)  ⊆  caller's permissions block
```

Pairs checked:

| Caller | Callee |
|---|---|
| `docs/CONSUMER-SETUP.md` `agent.yml` stub | `.github/workflows/agent-implement.yml` |
| `scripts/onboard-consumer.sh` `agent.yml` stub | `.github/workflows/agent-implement.yml` |
| `scripts/onboard-consumer.sh` chain stub | `.github/workflows/chain-dispatch.yml` |

**Subset, not equality.** A caller granting more than its callee needs is valid
and must not fail — the same reasoning as D3. Only a *shortfall* is a bug.

This is deliberately a second guard rather than an extension of #435's. That one
covers the in-repo test caller; this covers the shipped templates. They fail for
different reasons and have different remedies, and merging them would produce a
single failure message that fits neither.

**It will be verified to fail**: removing a key from a stub must turn the
assertion red. A guard that cannot fail is not a guard, and that is precisely
how this class survived three times.

### Component 2 — `--fix-permissions` on `migrate-consumers.sh`

The script already has `rewrite_pin <target> <force>` as a stdin→stdout filter,
with discovery, `--pr`, `--apply` and dry-run-by-default around it. The new mode
reuses all of that and adds a sibling filter:

```
rewrite_permissions <required>   — stub on stdin, rewritten stub on stdout
```

`<required>` is **computed, not hardcoded**: the union of
`agent-implement.yml`'s job permissions, read from this repo's own checkout at
run time. Hardcoding it would create a fifth place the set is written down —
the exact failure this spec exists to stop.

**Which file is swept:** the consumer's `.github/workflows/agent.yml` only.
That is what `migrate-consumers.sh` already discovers (by code search for
`agent-implement.yml`) and what calls the workflow whose permissions widened. A
consumer's chain-dispatch stub, where present, is a separate file calling a
separate workflow whose permissions have not changed; sweeping it is out of
scope and would need its own `<required>`.

Behaviour:

- Insert any key from `<required>` missing from the stub's `permissions:` block,
  preserving the block's existing keys, order and comments.
- **Never remove or downgrade** an existing key (D3).
- A stub with **no** `permissions:` block at all is reported and skipped, not
  patched — inserting a block means guessing where, and a consumer with no block
  is a different problem from one with a stale block.
- Unchanged stub ⇒ repo reported as already correct, no PR opened.

`--fix-permissions` is **incompatible with `--to`**: one call changes pins, the
other permissions, and a reviewer should see them separately.

### Component 3 — docs

`docs/CONSUMER-SETUP.md` gains a short note that the permission block must track
the reusable workflow's jobs, that a shortfall fails at load with no logs, and
that `migrate-consumers.sh --fix-permissions` sweeps a fleet. The symptom is the
searchable part: someone meeting `startup_failure` for the first time should
find this.

## The policy question, answered

Is widening a job's permissions a breaking change for a floating major tag?

**In effect, yes** — it breaks every consumer that does not widen with it, which
is what happened. But cutting a major for a one-line permission would mean
migrating 72 repos per occurrence, and consumers left behind on the old major
silently miss every later fix.

**Position taken:** keep the floating tag, and make the drift cheap to detect
and cheap to fix — the guard stops a stale template shipping, the sweep repairs
the fleet in one command. This is a deliberate trade, recorded so it is not
re-litigated as an oversight.

## Testing

| Case | Asserts |
|---|---|
| each pair in sync | passes |
| a key removed from the `CONSUMER-SETUP.md` stub | fails, naming that stub |
| a key removed from the `onboard-consumer.sh` agent stub | fails, naming that stub |
| chain stub checked against `chain-dispatch.yml`, not `agent-implement.yml` | passes — would fail under a single-union guard |
| caller granting a superset | passes |
| `rewrite_permissions`: missing key | inserted; other keys, order and comments intact |
| `rewrite_permissions`: already correct | byte-identical output |
| `rewrite_permissions`: superset | unchanged |
| `rewrite_permissions`: no `permissions:` block | reported and skipped, not patched |
| `--fix-permissions` without `--apply` | writes nothing |
| `--fix-permissions` with `--to` | usage error |

Existing `migrate-consumers` cases must pass unmodified.

## Acceptance criteria

- [ ] A Layer-1 test fails when any shipped stub grants less than the workflow
      it calls
- [ ] Each caller is checked against the callee it actually calls, so the chain
      stub passes
- [ ] A caller granting a superset passes
- [ ] The guard is verified to fail when a permission is removed
- [ ] `migrate-consumers.sh --fix-permissions` reports which consumers are short
      and, with `--apply`, opens a PR adding only the missing keys
- [ ] A consumer with no `permissions:` block is reported, not patched
- [ ] `--fix-permissions` with `--to` is a usage error
- [ ] `docs/CONSUMER-SETUP.md` names the symptom (`startup_failure`, no logs)
      and the sweep command
- [ ] `shellcheck -x` clean; full Layer-1 suite green

## Out of scope

- **Running the sweep.** This ships the tool; the fleet-wide PR round is an
  operator action, and 15–20 PRs is a decision rather than a side effect.
- **Cutting a major version** for permission widenings (*policy question*).
- **A `/gh:implement` pre-check.** Client-side, so it would guard only
  dispatches made through that command, and would be a fourth place the
  permission set is written down.
