# Scope boundaries — discovery vs. action

At the start of any multi-step session, state what's in scope in one sentence:
"In scope: X. Everything else found along the way gets written down, not acted on."

When you (Claude) find something outside that scope while working — a flaky test,
a missing CI gate, a vulnerable dependency, anything — that's a **discovery**, not
automatically a **task**. Default: capture it (`/capture-idea`, `TODO.md`, `/gh:new`,
`/fj:new`) and keep going on the original scope. Only turn a discovery into work if
I decide on purpose to expand scope.

**Stop and ask before expanding scope**, even for something that looks small. If
what you're about to do doesn't trace back to my original request, pause and ask:
"Found X — want me to fix this now (~Y min), or park it?" Don't silently expand.

**Watch for scope chains.** One hop past the original ask (a fix reveals one related
gap) is normal — just note it. Three or more hops from the same discovery
(A → B → C → D) means you've drifted into a different project: stop, write the
whole chain down as linked items, and ask before going any further down it.

**Separate the sweep from the fix.** A deliberate audit ("review CI health") and a
narrow fix ("finish these PRs") are different sessions with different attention
modes. Findings from one shouldn't get folded into the other mid-session — park
them for a dedicated pass instead.

**Limit open threads.** Don't have more than two things half-investigated at once.
For each thread: finish and merge, or park it as an issue/TODO entry — don't leave
a third thing dangling while starting a fourth.

If I don't set an explicit scope boundary myself, ask for one before starting
multi-step work rather than assuming everything you touch is in scope.
