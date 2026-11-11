# Decisions — ask in interview mode, never bury them in prose

Whenever you need me to make a decision — scope, which option, whether to push or
merge, how to resolve a conflict between two sources — **ask it as an interview**:
the structured question tool (`AskUserQuestion` in Claude Code), one question per
decision, each with concrete options and your recommendation **marked** (put it
first and label it `(Recommended)`). If you have no preference, say so in the
question rather than pretending to one.

Never end an answer with decisions I have to dig out of the text — no "let me know
which you prefer", no open questions in the middle of a summary, no checklist that
mixes things for me to *do* with things for me to *decide*. If the reply contains a
decision, the interview is where it lives; the prose around it only gives context.

**Why:** a decision hidden in a long answer gets missed or answered by guesswork
("do what's recommended" when nothing was marked as recommended). An interview makes
every open decision explicit, answerable in one click, and impossible to overlook.

Relation to `task-checklist.md`: that partial covers things for me to **do**
(manual steps, action items). Decisions are not tasks — they go here.
