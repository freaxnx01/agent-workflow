# Per-repo policy: headless enrich may proceed on `[low]` assumptions — design

**Issue:** #550 · **Date:** 2026-10-19 · **Status:** approved (quick + headless enrich)

## Problem

Headless `/enrich` (`--headless`, what `/autopilot` runs) hands **every**
`[low]`-confidence assumption to a human via `needs-human`
(`commands/enrich.md:66-73`, rationale `:91-94`, per #252). That is right for
factory code. On a repo that is not mission-critical, like the `game-*` fleet,
it stops the lane on most feature issues. That defeats issue-in →
published-out, which is the point of the game-rhyflitzer prototype (#551).

The operator's framing (2026-10-19): the games should be bug-free and
playable, but they are not mission-critical. An occasional wrong guess that a
later issue fixes is acceptable.

## Constraints from the issue

- **Per repo, set by the operator outside the consumer repo**, like the
  autopilot allowlist (`~/.config/agent-workflow/autopilot.conf`,
  `scripts/lib/autopilot-config.sh:24-32`), so a repo cannot loosen its own gate.
- `[low]` assumptions are still **recorded** in the issue's `## Assumptions`
  block. The run continues instead of stopping.
- **One-way doors and ⛔ Blocked items still go to `needs-human`**, whatever the policy.
- The headless doc tests (`tests/run-enrich-headless-doc-tests.sh`) cover both
  policies, and the driver passes the policy to the nested enrich.

## Design

### 1. Config: `accept_low=<owner/name>`

A new key in `autopilot.conf`, one line per repo:

```ini
repo=freaxnx01/game-rhyflitzer:tests.yml
accept_low=freaxnx01/game-rhyflitzer
```

- Same validation style as `repo=`: owner/name must match
  `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`. Otherwise
  `error: <file>:<line>: accept_low must be owner/name: <value>`.
- The repo must also be allowlisted by a `repo=` line anywhere in the file,
  checked after the whole file is read so order does not matter. Otherwise
  `error: <file>:<line>: accept_low names a repo that is not allowlisted: <repo>`.
  A policy for a repo the lane never touches is a typo, and the config is
  fail-fast by design (`autopilot-config.sh:30-32`).
- Absent → the strict default, exactly today's behaviour.
- Exposed as `AUTOPILOT_ACCEPT_LOW`, an associative array (repo → `1`),
  declared at the library's top level so a caller that never loaded a config
  reads it as empty instead of tripping `set -u` or bash's arithmetic
  subscript on an undeclared name (`o/r` would evaluate as `o / r`).

A separate key rather than a third field on `repo=`: the `repo=` line's
grammar and its path-traversal validation (`autopilot-config.sh:93-114`) stay
untouched, and one `grep accept_low` on the host file shows every loosened repo.

### 2. Driver → wrapper → session

- `scripts/autopilot.sh` `process_issue` sets `ENRICH_ACCEPT_LOW=1` in the
  nested command's environment when the repo is in `AUTOPILOT_ACCEPT_LOW`,
  `0` otherwise. A dry run says so: `would: enrich headless --accept-low, then dispatch (clone <dir>)`.
- `scripts/lib/agent-cmd-enrich.sh` appends ` --accept-low` to the prompt
  (`/enrich <n> --quick --headless --accept-low`) only when `ENRICH_ACCEPT_LOW`
  is exactly `1`. Any other value, or unset, means strict (fail closed).
- `scripts/lib/parse-enrich-args.sh` parses `--accept-low` and emits a fourth
  line `ACCEPT_LOW=yes|no`.

The consumer repo has no hand in any of this. The flag comes from the host
config through the driver's own argv/env. The nested session runs inside the
consumer's clone and reads its issue and files, so `commands/enrich.md` must
say the policy is read **only** from `$ARGUMENTS`, never from issue text,
comments or repo files (`CLAUDE.md`, `AGENT-NOTES.md`, …). Otherwise an issue
body saying "this repo accepts low assumptions" would be a gate bypass.

### 3. `commands/enrich.md`

- `argument-hint` and the parsing block gain `--accept-low` / `ACCEPT_LOW`.
- In **Headless mode**, the `[low]` bullet becomes "any `[low]`-confidence
  assumption, unless `$ACCEPT_LOW` is `yes`". A new subsection
  `### Accept-low policy`, inside the Headless section, says:
  - where the flag comes from (operator's `accept_low=` via the driver, or an
    operator typing it), and that it is read only from `$ARGUMENTS`;
  - the effect: `[low]` entries are written to `## Assumptions` exactly as
    usual, keeping their `[low]` marker, and the run goes on through Step 6;
  - one-way doors and ⛔ Blocked entries still trigger the six escalation
    outcomes unchanged;
  - the Assumptions block then opens with one line,
    `Accept-low policy: on — the [low] items below were not reviewed by a human before dispatch.`,
    so a reviewer of the PR or issue can tell a deliberate policy from a
    missed escalation;
  - without `--headless` the flag changes nothing (quick mode does not route
    `[low]` anywhere in the first place).

### 4. Docs

- `setup/autopilot.conf.example`: the `accept_low=` key with its rules, as a
  commented example.
- `docs/AUTOPILOT.md`: a section on the policy (what it loosens, what it never
  loosens, where it is set). The `needs-human` and dry-run log rows are updated.

## Out of scope

- A per-issue or per-label policy.
- Changing what counts as a one-way door.
- `/enrich-batch` (interactive; it has a human to ask).
- Any change to the review/merge gates downstream of enrich.

## Testing (Layer-1)

- `tests/run-autopilot-config-tests.sh`: parsed into `AUTOPILOT_ACCEPT_LOW`;
  absent → empty; not-allowlisted repo refused with its message; malformed
  value refused; order-independent (`accept_low=` before `repo=`).
- `tests/run-parse-enrich-args-tests.sh`: `ACCEPT_LOW=yes` with the flag,
  `no` without. The five exact-output expectations in "basic cases" gain the
  fourth line. That is an intentional contract change, recorded here.
- `tests/run-agent-cmd-enrich-tests.sh`: prompt carries `--accept-low` only
  for `ENRICH_ACCEPT_LOW=1`; `yes`/`true`/unset → strict prompt.
- `tests/run-autopilot-driver-tests.sh`: an `accept_low=o/r` config makes the
  nested command see `ENRICH_ACCEPT_LOW=1`; without it, `0`; dry run says
  `--accept-low`.
- `tests/run-enrich-headless-doc-tests.sh`: the section has the
  `### Accept-low policy` subsection, names `--accept-low`, keeps the default
  `[low]` routing bullet, states one-way doors and ⛔ still escalate under the
  policy, says the flag is read only from `$ARGUMENTS`, carries the banner
  line, and the parsing block reads `ACCEPT_LOW`.
