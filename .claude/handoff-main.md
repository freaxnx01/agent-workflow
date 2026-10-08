## Resume: Azure DevOps forge support — complete, nothing in flight

**Artifact:** `docs/ai-notes/2026-09-25-ado-forge-support-complete.md`

Azure DevOps is a finished, verified forge in this repo. Both halves work against a
live organization: the twelve interactive commands (#286) and the pipeline adapter
(#253, `scripts/lib/forge.sh` + `scripts/implement-azdo.sh`).
Issues #253, #286, #386, #387 and #397 are all closed and every PR merged.
`main` is green at 26 runners / 0 failed.

**Next step:** nothing is outstanding on ADO. Read the artifact before starting any
follow-up — it records the decisions that should not be re-litigated (shell adapter
rather than a skill; factory repos on Claude while product repos keep the cheap
fleet default; the 40 `game-*` repos deliberately left without `actions: write`),
and what was deliberately left undone (the ADO merge envelope and re-dispatch, both
inherent to the forge). If the merge envelope is ever wanted, **open a fresh
issue** — #253's premise was superseded and reopening it would carry the wrong
framing.

**Do not delete `agent-workflow-sandbox`** in the personal org
`AndreasImboden0022`. It is the only place ADO changes can be verified, and its
fixtures each prove something specific. Credentials: `direnv exec ~/repos/ado/personal …`.
Never write to the `bossinfo` org — the PAT reaches it and it is production.

For any implementation work that follows, use
**`superpowers:subagent-driven-development`**.
