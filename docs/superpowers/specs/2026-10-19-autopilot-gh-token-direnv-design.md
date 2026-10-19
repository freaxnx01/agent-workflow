# The autopilot lane gets GH_TOKEN from direnv, never from a second copy — design

**Issue:** #509 · **Date:** 2026-10-19 · **Status:** approved (quick + headless enrich; credential-touching, see "One-way door")

## Problem

In #373 run 3, the headless enrich stopped because `GH_TOKEN` was unset. The
driver inherits its environment from whatever starts it. A `--user` systemd
unit inherits nothing, and `autopilot.env` held only `CLAUDE_CODE_OAUTH_TOKEN`.

The documented fix is to copy the PAT into `autopilot.env`
(`docs/AUTOPILOT.md:78-81`, `setup/agent-autopilot.service:24-31`). That
conflicts with the operator rule: GitHub auth is **only** the PAT that direnv
exports from Passbolt (`~/repos/github/freaxnx01/public/.envrc`). A second
copy drifts, outlives a rotation, and hides an expiry.

What worked live: `direnv exec ~/repos/github/freaxnx01/public bash -c '…autopilot.sh --max 1'`
(#373 run 4 merged end to end).

## The open question, measured

*Does `passbolt get` work from a `--user` unit with no interactive session?*
Yes, on this host. Measured 2026-10-19:

```text
systemd-run --user --wait --pipe -q /usr/bin/env -i HOME=/home/freax PATH=/usr/bin:/bin \
  /usr/bin/direnv exec /home/freax/repos/github/freaxnx01/public <probe>
→ GH_TOKEN set, length 40
→ gh api user → freaxnx01
```

The reason: go-passbolt-cli keeps the private key and its passphrase in its
own config (`~/.config/go-passbolt-cli/go-passbolt-cli.toml`, mode 0600, keys
`userprivatekey` / `userpassword`), so there is no GPG agent or pinentry. The
user has `Linger=yes`, so `--user` timers fire without a login session. The
timer path and the manual path need the same answer, and this is it.

Two conditions, both documented rather than coded:

- The `.envrc` must be `direnv allow`ed by the unit's user (direnv's allow
  database is per user, so this holds for the unit as for the shell).
- Passbolt must be reachable. The `.envrc` sends passbolt's stderr to
  `/dev/null`, so an outage yields an **empty** `GH_TOKEN`, not an error. The
  driver's fail-fast check (below) catches that.

## Design

### 1. The unit wraps the driver in `direnv exec`

```ini
EnvironmentFile=%h/.config/agent-workflow/autopilot.env      # CLAUDE_CODE_OAUTH_TOKEN only
WorkingDirectory=%h/repos/github/freaxnx01/public/agent-workflow
ExecStart=/usr/bin/direnv exec %h/repos/github/freaxnx01/public %h/repos/github/freaxnx01/public/agent-workflow/scripts/autopilot.sh
```

- No `bash -c '…'`. systemd expands `$VAR` / `${VAR}` in `ExecStart` itself,
  before the shell sees it. That was observed in the probe above: a
  `systemd-run … bash -c '… ${#GH_TOKEN} …'` printed an empty length.
  `direnv exec <dir> <program>` needs no shell and no `$`.
- `/usr/bin/direnv` is absolute, with a comment to fix it from `command -v direnv`.
- The comment block lists the three paths to edit (direnv dir, clone,
  driver) and the `direnv allow` prerequisite. It no longer mentions `GH_TOKEN=`.
- `EnvironmentFile` stays for `CLAUDE_CODE_OAUTH_TOKEN`. That is not GitHub
  auth, and the operator rule does not cover it.

### 2. The driver fails fast without `GH_TOKEN`

`scripts/autopilot.sh` checks `GH_TOKEN` is non-empty and exits with a **new
exit code 5** and a named error:

```text
error: GH_TOKEN is not set — start the driver under direnv: direnv exec <dir with the .envrc> scripts/autopilot.sh (see docs/AUTOPILOT.md, "Credentials")
```

- **Where:** after the run lock and the kill switch, before the config load.
  "already running" and "disabled" stay exit 0 with no token: neither touches
  GitHub, and the kill switch must work even when credentials are broken.
- **Dry runs too.** `--dry-run` reads GitHub (eligibility, candidates), so it
  needs the token like a real run.
- **Env only.** The check is on the variable, not on `gh auth status`. A
  stored `gh` OAuth login (`~/.config/gh/hosts.yml`) must **not** satisfy it.
  Falling back to that is exactly what the operator rule forbids, and what hid
  an expired PAT for days in 2026-10.
- No network call. Whether the token is valid is found by the first `gh`
  call, as today. The check only turns "nested session discovers it 30 minutes
  later" into "run refuses in the first second".

### 3. Docs

- `docs/AUTOPILOT.md` Setup step 2: `autopilot.env` holds
  `CLAUDE_CODE_OAUTH_TOKEN` only. `GH_TOKEN` comes from the direnv-exported
  PAT and is never copied. Steps 3–4 show the `direnv exec` launch line. The
  exit-code table gains `5`. "When something is wedged" gains a bullet for
  exit 5 (direnv not allowed, Passbolt unreachable, or launched without direnv).
- `commands/autopilot.md`: exit code `5` in its list. Its two invocations
  stay as they are: a Claude session started from the direnv directory
  already has `GH_TOKEN`, and the driver now says so loudly when it does not.

## One-way door

This touches credential handling, which enrich treats as a one-way door. The
direction is not the agent's decision: the operator set it in the issue body
and in the standing rule ("GitHub auth is only the direnv-exported PAT; never
a second copy, never another token"). The spec follows it to the letter. Under
the headless rules the issue is still handed to a human (`needs-human`) for a
confirmation before dispatch.

## Out of scope

- Removing `GH_TOKEN` from an existing host's `autopilot.env`. That is a host
  action; the docs say to do it.
- Validating the token (expiry, scopes) in the driver.
- Any change to how `CLAUDE_CODE_OAUTH_TOKEN` is supplied.

## Testing

Layer-1, `tests/run-autopilot-driver-tests.sh` (gh mocked):

- `GH_TOKEN` unset → exit 5, error names `direnv`, zero gh calls.
- `GH_TOKEN` set but empty → exit 5.
- `GH_TOKEN` unset + kill switch present → exit 0, `disabled` logged.
- `GH_TOKEN` unset + `--dry-run` → exit 5.
- The test file exports a dummy `GH_TOKEN` at the top, so every existing case
  runs as before.
- Static checks on `setup/agent-autopilot.service`: `ExecStart` runs
  `direnv exec`, contains no `$`, and the file no longer instructs `GH_TOKEN=`.
  On `docs/AUTOPILOT.md`: no `GH_TOKEN=` in the credentials step, and exit
  code `5` is documented.
