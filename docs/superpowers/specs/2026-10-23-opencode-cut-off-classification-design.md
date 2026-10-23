# opencode cut-off after a `tool-calls` step — classify as transient (#558)

## Problem

An opencode run whose **last** `step_finish` event carries `reason: "tool-calls"` stopped
after asking for tool calls and before the model answered. The agent loop was cut off;
the task did not finish. Today `scripts/adapt-opencode-result.sh` sees no `error` event
and emits `subtype: "success"`, `is_error: false`, so `scripts/classify-failure.sh` returns
`class=success`, `scripts/retry-dispatch.sh` never retries, and the run report says
"failed: run completed but no PR was opened".

Seen on freaxnx01/game-rhyflitzer#353, run 39326381307 (2026-10-19, `z-ai/glm-5.3`):
the raw stream is exactly `step_start`, two `tool_use` events, and one `step_finish` with
`reason: "tool-calls"`, 0 output tokens. The first `tool_use` (a `read` of a mistyped path
outside the checkout) has `state.status: "error"` and `state.error: "The user rejected
permission to use this specific tool call."` — opencode's headless permission handling
rejected it and the session ended after that step. Sibling dispatches on the same model at
the same minute ran normally; a re-dispatch of #353 produced a PR.

## Design

### Detection (adapter)

`adapt-opencode-result.sh` marks a stream as **cut off** when both hold:

1. the stream has **no** `error` events (errors keep today's `error_during_execution`
   path, which carries the provider evidence the classifier relies on), and
2. the **last** `step_finish` event's `.part.reason` is `"tool-calls"`.

A stream with no `step_finish` at all is unchanged (out of scope). Earlier `tool-calls`
steps are normal: `tests/fixtures/opencode-success.json` has one mid-stream and ends with
`reason: "stop"`; only the last step counts.

For a cut-off stream the adapter emits:

- `subtype: "error_agent_cut_off"`
- `is_error: true`
- `result`: `"OpenCode stopped after a tool-calls step, before the model answered (agent loop cut off). Model: <MODEL>"`
- every other field (turns, tokens, cost, duration, session id) computed exactly as today.

The result text deliberately avoids words the classifier's text regexes match
(`timeout`, `network`, digit runs like `5xx`), and the classifier does not read it for this
case anyway.

### Classification

`classify-failure.sh` gains one branch, directly after the `success` check:

```bash
elif [[ "$subtype" == "error_agent_cut_off" ]]; then
  class=transient
```

It keys on the structural `subtype`, not on result text — the script already treats text
channels as untrusted (#521). Placing it before the provider/text branches is safe: the
adapter only emits this subtype when the stream has no error events, so there is no
`api_error_status` to compete with.

`transient` then retries through the existing policy in `retry-dispatch.sh`
(`MAX_RETRIES_TRANS`, default 3, backoff 10/20/40 s). No workflow change:
`agent-implement.yml` already wires adapter → classifier → retry.

### Reporting

`post-run-report.sh` already treats `is_error: true` / `error_*` subtypes as failed and
shows the subtype; the report now reads as a failed run with the cut-off message instead
of a "success" with no PR.

## Acceptance criteria

- A stream ending in `step_finish` `reason: "tool-calls"` with no error events → adapter
  `is_error: true`, `subtype: "error_agent_cut_off"`; classifier `class=transient`.
- `tests/fixtures/opencode-success.json` (mid-stream `tool-calls`, last `stop`) stays
  `is_error: false`, `class=success`.
- A stream with an `error` event whose last `step_finish` is `tool-calls` keeps
  `subtype: "error_during_execution"` and its existing class.
- New fixtures: raw `opencode-cut-after-tool-calls.json`, canonical
  `result-opencode-cut-after-tool-calls.json`.
- `tests/run-script-tests.sh` and `tests/run-all.sh` pass.

## Out of scope

- The Claude agent path.
- A stream with no `step_finish` event at all.
- opencode's permission configuration for paths outside the checkout (the trigger seen
  in run 39326381307); worth its own issue.
