# Transcript — "Transform Coding Agent" (ChatGPT, 2026-08-19)

Raw source transcript for `2026-08-19-coding-agent-to-software-factory.md`, which
holds the distilled version with the already-built / new / rejected split. Kept
verbatim so the ASCII diagrams and the exact wording survive; converted from a
SingleFile HTML capture of the ChatGPT thread (the 2.4 MB HTML itself is not
committed — it is almost entirely base64-encoded UI assets).

External material, not a decision record. Nothing here is authoritative for this
repo; see `docs/DECISIONS.md` for what was actually adopted.

---

## User

How to transform Coding Agent into Software Factory?

---

## ChatGPT

Yes. The key shift is:

> **Don't make the Coding Agent better at coding. Make the system better at moving software work through a controlled production line.**

A Coding Agent is a **worker**.
A Software Factory is the **system around the workers**: intake → specification → decomposition → implementation → verification → review → release → feedback.

This is very close to the SDLC you sketched previously, but I'd make the stages explicit and **artifact-driven**.

### 1. From Coding Agent → Software Factory

Think of it like this:

```
                         SOFTWARE FACTORY
 ┌──────────────────────────────────────────────────────────────┐
 │                                                              │
 │  Requirements                                               │
 │       │                                                      │
 │       ▼                                                      │
 │  ┌─────────┐    ┌──────────┐    ┌──────────┐               │
 │  │  Intake │───▶│  Specify │───▶│ Decompose│               │
 │  └─────────┘    └──────────┘    └────┬─────┘               │
 │                                      │                      │
 │                              ┌───────▼───────┐              │
 │                              │ Agent Routing │              │
 │                              └───────┬───────┘              │
 │                                      │                      │
 │                    ┌─────────────────┼────────────────┐     │
 │                    ▼                 ▼                ▼     │
 │                 Coding            Tests           Docs      │
 │                  Agent            Agent           Agent     │
 │                    │                 │                │     │
 │                    └─────────────────┼────────────────┘     │
 │                                      ▼                      │
 │                               ┌────────────┐                │
 │                               │ Verification│               │
 │                               └──────┬─────┘                │
 │                                      ▼                      │
 │                               ┌────────────┐                │
 │                               │ Human Gate │                │
 │                               └──────┬─────┘                │
 │                                      ▼                      │
 │                                   Release                   │
 │                                      │                      │
 │                                      ▼                      │
 │                              Production Feedback            │
 │                                      │                      │
 │                                      └───────▶ Issues       │
 └──────────────────────────────────────────────────────────────┘
```

The important thing is that **the agent is no longer the workflow**.

It becomes one component inside the workflow.

GitHub's current agentic-SDLC guidance is moving in exactly this direction: agents can plan, implement, test, review and work asynchronously, while humans remain responsible for validation and approval. [GitHub Docs+1](https://docs.github.com/en/enterprise-cloud%40latest/copilot/tutorials/rolling-out-github-copilot-at-scale/enabling-developers/integrating-agentic-ai)

---

### 2. The most important architectural change: artifacts

Don't pass information primarily through prompts.

Pass it through **persistent artifacts**.

For example:

```
requirement
    │
    ▼
requirements.md
    │
    ▼
spec.md
    │
    ▼
architecture.md
    │
    ▼
tasks/
   ├── ISSUE-123.md
   ├── ISSUE-124.md
   └── ISSUE-125.md
    │
    ▼
implementation
    │
    ▼
PR
    │
    ├── test-results
    ├── review-results
    └── evidence.md
    │
    ▼
release
```

This is one of the biggest differences between an **AI assistant** and an **AI software factory**.

The Microsoft `agentic-sdlc-starter`, for example, explicitly separates assessment → specification → generation → validation and treats the generated artifacts as part of the pipeline. [GitHub](https://github.com/microsoft/agentic-sdlc-starter)

The principle I'd use is:

> **Every stage consumes a well-defined artifact and produces another well-defined artifact.**

That makes the process inspectable, resumable and automatable.

---

### 3. Your existing process is already the skeleton

Your previous process:

```
Create Issues
      ↓
Assign Milestone
      ↓
Enrich Issues
  Spec
  Implementation Plan
      ↓
Route
  Copilot / AI implementation
      ↓
HITL Review
      ↓
Manual Tests
      ↓
Test Feedback
      ↓
Create Issues
      ↓
Documentation
      ↓
Release
```

I'd evolve it into:

```
                    ┌──────────────────┐
                    │    REQUIREMENT   │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │      INTAKE      │
                    │ classify / dedup │
                    │ priority / scope │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │      SPEC        │
                    │ acceptance       │
                    │ architecture     │
                    │ constraints      │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │    DECOMPOSE     │
                    │ issues / tasks   │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │      ROUTER      │
                    │ which agent?     │
                    │ which model?     │
                    │ which workflow?  │
                    └────────┬─────────┘
                             ↓
                    ┌──────────────────┐
                    │   IMPLEMENT      │
                    │ Coding Agent     │
                    └────────┬─────────┘
                             ↓
               ┌─────────────┴─────────────┐
               ↓                           ↓
```

That's a **factory loop**, rather than a coding workflow.

---

### 4. Introduce specialized agents

Don't have one giant "Software Engineer Agent".

Have roles.

For example:

| Agent | Responsibility |
| --- | --- |
| **Intake Agent** | Understand incoming requirement |
| **Analyst Agent** | Detect ambiguity, missing information |
| **Architect Agent** | Produce technical design |
| **Planner Agent** | Break into implementation issues |
| **Coding Agent** | Implement one bounded issue |
| **Test Agent** | Create/run tests |
| **Review Agent** | Review implementation against spec |
| **Security Agent** | Security analysis |
| **Documentation Agent** | Update docs |
| **Release Agent** | Prepare release |
| **Feedback Agent** | Turn failures/feedback into issues |

The Coding Agent then becomes almost boring:

> **Given a validated task, implement it within the defined boundaries.**

That's actually desirable.

---

### 5. Give every agent a contract

For example:

```yaml
agent: coding-agent

input:
  required:
    - issue
    - specification
    - implementation_plan
    - repository
  optional:
    - architecture
    - previous_feedback

must:
  - understand existing architecture
  - implement acceptance criteria
  - add/update tests
  - run required quality checks
  - document relevant changes

must_not:
  - change unrelated code
  - change architecture without approval
  - modify requirements
  - bypass failing tests
  - silently make assumptions

output:
  - source_changes
  - tests
  - implementation_summary
  - evidence
  - unresolved_questions
```

This is much more powerful than adding another 500 lines to a system prompt.

---

### 6. Add **quality gates**, not just agents

This is probably the most important part.

A factory should be able to say:

```
             Implementation
                   │
                   ▼
             ┌───────────┐
             │ Build     │
             └─────┬─────┘
                   │ PASS
                   ▼
             ┌───────────┐
             │ Unit Test │
             └─────┬─────┘
                   │ PASS
                   ▼
             ┌───────────┐
             │ Integration│
             │ Tests      │
             └─────┬─────┘
                   │ PASS
                   ▼
             ┌───────────┐
             │ Security  │
             └─────┬─────┘
                   │ PASS
                   ▼
             ┌───────────┐
             │ AI Review │
             └─────┬─────┘
                   │ PASS
                   ▼
             ┌───────────┐
             │ HITL      │
             └─────┬─────┘
                   │
                 MERGE
```

**Deterministic checks should dominate LLM judgement wherever possible.**

For example:

```
compile       → deterministic
unit tests    → deterministic
lint          → deterministic
API contract  → deterministic
security scan → deterministic
coverage      → deterministic

architecture review → AI
UX review            → AI
requirement fit     → AI + human
business decision   → human
```

That's how you prevent the factory from becoming "a bunch of agents agreeing with each other."

GitHub's agentic workflows similarly emphasize guardrails, permissions, automated checks and human approval rather than unrestricted agent autonomy. [GitHub Docs](https://docs.github.com/en/copilot/concepts/agents/about-github-agentic-workflows)

---

### 7. Make the Issue the factory's work order

I'd make your GitHub Issue significantly richer.

For example:

```yaml
---
type: feature
status: ready-for-implementation
spec_version: 3
agent: coding
risk: medium
---

# Feature

...

## Goal

...

## Non-goals

...

## Acceptance Criteria

- [ ] ...
- [ ] ...
- [ ] ...

## Technical Specification

...

## Implementation Plan

1. ...
2. ...
3. ...
```

Now the issue isn't merely a ticket.

It becomes a **production work order**.

---

### 8. Introduce a Router

This is where the factory starts becoming interesting.

Instead of:

```
Issue → Copilot
```

you have:

```
                         Issue
                           │
                           ▼
                      ┌─────────┐
                      │ Router  │
                      └────┬────┘
                           │
          ┌────────────────┼─────────────────┐
          ↓                ↓                 ↓
       trivial           normal            complex
          │                │                 │
          ▼                ▼                 ▼
      fast agent       coding agent      architect
                                           ↓
                                      implementation
```

And potentially:

```
bug                 → bugfix agent
documentation       → docs agent
test coverage       → test agent
refactoring         → refactoring agent
security finding    → security agent
feature             → planner → coding
architecture change → human architecture gate
```

GitHub now supports assigning coding-agent work to custom agents, which is useful for exactly this type of specialization. [GitHub Docs+1](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/kick-off-a-task)

---

### 9. The really important concept: bounded autonomy

Don't aim for:

> "AI develops software completely autonomously."

Aim for:

> **AI can autonomously progress work until it encounters a defined decision boundary.**

For example:

```
                    START
                      │
                      ▼
                  Agent works
                      │
             ┌────────┴────────┐
             │                 │
        deterministic       decision
          problem            required
             │                 │
             ▼                 ▼
         fix/retry          HITL
             │                 │
             └────────┬────────┘
                      ▼
                    continue
```

Examples of automatic decisions:

```
test failed
→ inspect → fix → retry

lint failed
→ fix → retry

implementation incomplete
→ continue

review found trivial issue
→ fix → retry
```

Examples of human gates:

```
architecture change
security risk
scope expansion
breaking API
database migration
requirement ambiguity
production deployment
```

This gives you **high autonomy without pretending everything is safe to automate**.

---

### 10. Make the feedback loop first-class

This is the part many "AI coding" systems miss.

Your factory shouldn't end at:

```
PR merged
```

It should be:

```
                         RELEASE
                            │
                            ▼
                       PRODUCTION
                            │
              ┌─────────────┼──────────────┐
              ↓             ↓              ↓
           errors        telemetry       users
              │             │              │
              └─────────────┼──────────────┘
                            ↓
                       Feedback Agent
                            │
                            ▼
                       New Issue
                            │
                            └───────▶ FACTORY
```

That creates the actual **software manufacturing loop**:

> **Build → Verify → Release → Observe → Learn → Build again**

---

### 11. Your factory needs a control plane

Eventually you'll want something sitting above GitHub/Copilot/Claude/etc.

Conceptually:

```
                     SOFTWARE FACTORY
                         CONTROL PLANE
                              │
        ┌─────────────┬───────┼────────┬──────────────┐
        │             │       │        │              │
     Backlog       Specs    Router   Agents       Quality
        │             │       │        │              │
        └─────────────┴───────┼────────┴──────────────┘
                              │
                     Execution Engine
                              │
             ┌────────────────┼────────────────┐
             ↓                ↓                ↓
          Copilot          Claude            Codex
          Agent             Code             Agent
             │                │                │
             └────────────────┼────────────────┘
                              ↓
                         Git / PR / CI
```

The control plane should know:

```
What work exists?
What state is it in?
Which agent owns it?
What artifact is expected?
What gate failed?
What needs a human?
What can run automatically?
What happened historically?
```

That is what turns agents into a **system**.

---

### 12. State machine > prompt chain

I'd explicitly model the lifecycle.

For example:

```
NEW
 │
 ▼
TRIAGED
 │
 ▼
SPEC_REQUIRED
 │
 ▼
SPEC_READY
 │
 ▼
PLANNED
 │
 ▼
READY_FOR_AGENT
 │
 ▼
IMPLEMENTING
 │
 ▼
VERIFYING
 │
 ├── FAILED ──▶ IMPLEMENTING
 │
 ▼
AI_REVIEW
 │
 ├── CHANGES_REQUIRED ──▶ IMPLEMENTING
 │
 ▼
HUMAN_REVIEW
 │
 ├── CHANGES_REQUIRED ──▶ IMPLEMENTING
 │
 ▼
```

This is much more robust than trying to orchestrate everything through one LLM prompt.

---

### 13. I'd build it in 4 maturity levels

### Level 1 — Agent-assisted

```
Human
  ↓
Issue
  ↓
Coding Agent
  ↓
PR
  ↓
Human
```

You essentially have this today.

### Level 2 — Agentic pipeline

```
Issue
 ↓
Spec Agent
 ↓
Planning Agent
 ↓
Coding Agent
 ↓
Test Agent
 ↓
Review Agent
 ↓
Human
```

This is probably your **next step**.

### Level 3 — Software Factory

```
Requirements
 ↓
Automatic triage
 ↓
Specification
 ↓
Decomposition
 ↓
Routing
 ↓
Parallel implementation
 ↓
Automated verification
 ↓
AI review
 ↓
HITL
 ↓
Merge
 ↓
Release
 ↓
Feedback
 ↺
```

### Level 4 — Adaptive Factory

The factory itself starts optimizing:

```
                   ┌──────────────────┐
                   │ Software Factory │
                   └────────┬─────────┘
                            │
                       metrics
                            │
             ┌──────────────┼──────────────┐
             ↓              ↓              ↓
          quality         cost           speed
             │              │              │
             └──────────────┼──────────────┘
                            ↓
                     Factory Optimizer
                            │
                 ┌──────────┴─────────┐
                 ↓                    ↓
             change routing       improve agents
```

For example:

> "Features implemented by Agent A have 30% more review iterations than Agent B."

→ Router changes.

Or:

> "Tasks with >5 files have a 70% higher failure rate."

→ Planner starts splitting those tasks differently.

That's when you really have a **software factory**, rather than an automated SDLC.

---

### 14. The core design principle

I'd summarize the whole transformation as:

```
        CODING AGENT

             │
             │
             ▼

     "Implement this issue"

             ↓

      SOFTWARE FACTORY

  ┌─────────────────────────┐
  │                         │
  │     What should we      │
  │        build?           │
  │            ↓            │
  │     Is it specified?    │
  │            ↓            │
  │     How do we split it? │
  │            ↓            │
  │     Who should do it?   │
  │            ↓            │
  │     Can it be verified? │
  │            ↓            │
  │     Is it correct?      │
  │            ↓            │
  │     Should a human      │
  │     approve it?         │
  │            ↓            │
  │     Can we release it?  │
  │            ↓            │
  │     What did we learn?  │
  │            │            │
```

The emerging industry pattern is very similar: **spec-driven development + specialized agents + deterministic quality gates + human approval + continuous feedback**. Microsoft's reference architecture explicitly uses assessment/specification/generation/validation stages, while GitHub's current agentic workflows add repository automation around agents with explicit security and approval boundaries. [GitHub+1](https://github.com/microsoft/agentic-sdlc-starter)

### For your setup specifically

Given your earlier **"Create Issues → Enrich → Route → HITL → Test → Feedback → Docs → Release"** process, I would **not** start by building a giant multi-agent framework.

I'd build these five things first:

```
1. Issue Contract
   ↓
2. Spec / Implementation Plan artifact
   ↓
3. Agent Router
   ↓
4. Automated Quality Gate
   ↓
5. Lifecycle State Machine
```

Then plug **Copilot Coding Agent** into the `IMPLEMENTING` state.

That gives you the crucial inversion:

> **Today:** the human orchestrates the agent.
> **Next:** the factory orchestrates the agents, and the human handles exceptions and decisions.

That is the point at which a **Coding Agent becomes a Software Factory**.

---

## User

* Contract YAML: Concrete form when working with Claude?
* How to implement Quality Gates technically?

---

## ChatGPT

Yes. For Claude Code, I would make the **YAML contract a real file in the repository**, not something you paste into the prompt each time.

The second important point is: **Quality Gates should be executable CI/workflow rules, not instructions to Claude.** Claude can *run* and interpret them, but it must not be the authority that declares itself successful.

### 1. Contract YAML with Claude Code

A useful repository structure could be:

```
.factory/
├── contracts/
│   ├── feature.yaml
│   ├── bugfix.yaml
│   └── refactoring.yaml
├── agents/
│   ├── coding.yaml
│   ├── testing.yaml
│   └── reviewer.yaml
├── gates/
│   ├── build.yaml
│   ├── tests.yaml
│   ├── api.yaml
│   └── security.yaml
└── workflows/
    └── implementation.yaml
```

For Claude specifically, the contract isn't a special Claude format. Claude Code can read normal repository files and instructions. The contract becomes **the machine-readable source of truth**.

For example:

```yaml
# .factory/contracts/feature.yaml

kind: implementation-contract
version: 1

agent:
  role: coding-agent
  autonomy: bounded

input:
  issue: required
  specification: required
  implementation_plan: required

scope:
  allowed:
    - src/**
    - tests/**
  forbidden:
    - .github/workflows/**
    - infrastructure/**
  max_files_changed: 20

requirements:
  acceptance_criteria: required
  tests: required

actions:
  allowed:
    - modify_source
    - add_tests
    - run_tests
    - run_build

  forbidden:
    - change_requirements
```

Then your Claude Code instruction can be very small:

```
Implement the assigned issue.

Before starting:
1. Read .factory/contracts/feature.yaml
2. Read the issue
3. Read the specification
4. Read the implementation plan

Follow the contract exactly.

Do not modify files outside the allowed scope.

Before declaring completion, run all applicable quality gates and report
the results. Do not claim a gate passed unless the command actually
returned success.
```

### But there is an important distinction

The YAML **doesn't enforce anything by itself**.

Claude can theoretically ignore:

```yaml
forbidden:
  - .github/workflows/**
```

Therefore:

> **Contract = declared policy.
> Enforcement layer = actual policy.**

That's where Quality Gates come in.

---

### 2. Quality Gates technically

I'd divide them into **three layers**.

```
             Claude
               │
               ▼
        ┌──────────────┐
        │ Local Gates  │
        └──────┬───────┘
               │
               ▼
              PR
               │
               ▼
        ┌──────────────┐
        │ CI Gates     │
        └──────┬───────┘
               │
               ▼
        ┌──────────────┐
        │ Merge Gate   │
        └──────┬───────┘
               │
               ▼
             MERGE
```

The **CI system is the final authority**, not Claude.

For your .NET projects, this can be very concrete.

---

### 3. Gate 1: Build

For example:

```bash
dotnet restore
dotnet build --configuration Release --no-restore
```

Exit code:

```
0 → PASS
!= 0 → FAIL
```

That's already a quality gate.

Claude can execute it, but your CI executes it again independently.

---

### 4. Gate 2: Tests

```bash
dotnet test \
  --configuration Release \
  --no-build \
  --logger "trx;LogFileName=test-results.trx"
```

Again:

```
exit 0 → PASS
exit != 0 → FAIL
```

You can additionally enforce coverage:

```bash
dotnet test \
  --collect:"XPlat Code Coverage"
```

and then have a script evaluate:

```
line coverage >= 80%
branch coverage >= 70%
```

The important thing is that **the threshold is executable**, not merely written in the issue.

---

### 5. Gate 3: Static analysis

For .NET:

```bash
dotnet format --verify-no-changes
```

Potentially:

```bash
dotnet build \
    /warnaserror
```

Then:

```
compiler warnings → failure
format violations → failure
```

You can also add tools such as analyzers/security scanners depending on your project.

---

### 6. Gate 4: API contract

This is particularly interesting for your API projects.

Suppose you have:

```
openapi.yaml
```

You can validate:

```bash
openapi lint openapi.yaml
```

But you can go further.

For example:

```
existing API
      +
new implementation
      ↓
API compatibility check
      ↓
breaking change?
      │
   ┌──┴──┐
   │     │
  NO    YES
   │     │
 PASS   FAIL
```

That prevents an agent from accidentally changing:

```http
GET /users/{id}
```

from:

```json
{
  "id": "...",
  "name": "..."
}
```

to something incompatible.

For your API-heavy work, I'd make **API compatibility its own mandatory gate**.

---

### 7. Gate 5: Architecture / scope

This is where your YAML contract becomes interesting.

Suppose the issue says:

```yaml
scope:
  allowed:
    - src/UserService/**
    - tests/UserService/**
```

The agent modifies:

```
src/UserService/UserService.cs
tests/UserService/UserServiceTests.cs
```

Fine.

But:

```
src/Authentication/AuthService.cs
```

appears in the PR.

A gate can detect this.

For example, a simple script:

```powershell
$allowed = @(
    "src/UserService/**",
    "tests/UserService/**"
)

$changedFiles = git diff --name-only origin/main...HEAD

foreach ($file in $changedFiles) {
    if (-not (Test-PathMatchingPattern $file $allowed)) {
        Write-Error "File outside allowed scope: $file"
        exit 1
    }
}
```

Now the agent **cannot expand its scope silently**.

---

### 8. Gate 6: Acceptance criteria

This is where I'd use an AI gate.

You can have:

```
Issue
  │
  ├── Acceptance criteria
  │
  └── PR
        │
        ▼
     Review Agent
        │
        ▼
 acceptance.json
```

For example:

```json
{
  "criteria": [
    {
      "id": "AC-001",
      "result": "pass",
      "evidence": "UserServiceTests..."
    },
    {
      "id": "AC-002",
      "result": "pass",
      "evidence": "..."
    },
    {
      "id": "AC-003",
      "result": "fail",
      "evidence": "..."
    }
  ],
  "overall": "fail"
}
```

But there's a crucial rule:

> **AI review can produce a gate result, but the pipeline must decide what that result means.**

Don't let Claude say:

> "Looks good, therefore PASS."

Instead:

```
Review Agent
     ↓
structured result
     ↓
JSON schema validation
     ↓
gate evaluator
     ↓
PASS / FAIL
```

---

### 9. The gate runner

This is the component I'd build early.

Something like:

```
.factory/gates/
    build.ps1
    test.ps1
    format.ps1
    api.ps1
    scope.ps1
    acceptance.ps1
```

and:

```
.factory/run-gates.ps1
```

Conceptually:

```powershell
$gates = @(
    "build",
    "test",
    "format",
    "api",
    "scope"
)

foreach ($gate in $gates) {
    Write-Host "Running gate: $gate"

    & ".factory/gates/$gate.ps1"

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Gate failed: $gate"
        exit 1
    }
}

Write-Host "All gates passed"
exit 0
```

Now you have a **single deterministic factory interface**:

```bash
./.factory/run-gates.ps1
```

Claude can run it.

CI can run it.

A human can run it.

Your future orchestration service can run it.

That's extremely valuable.

---

### 10. Put the same gate into CI

For GitHub:

```yaml
name: Quality Gates

on:
  pull_request:

jobs:
  quality:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.x'

      - name: Quality Gates
        shell: pwsh
        run: ./.factory/run-gates.ps1
```

Now the flow becomes:

```
Claude
  │
  │ modifies code
  ▼
PR
  │
  ▼
GitHub Actions
  │
  ├── Build        ✓
  ├── Tests        ✓
  ├── Format       ✓
  ├── API          ✓
  ├── Scope        ✓
  └── Security     ✓
          │
          ▼
       MERGEABLE
```

And GitHub branch protection can require the quality job to pass before merging.

That is a **real enforcement boundary**.

---

### 11. Don't make Claude responsible for its own gate

This distinction is fundamental.

### Bad

```
Claude:

Implement feature.
Run tests.
If everything looks good, commit.
```

Claude is:

```
worker + judge + gatekeeper
```

### Better

```
Claude
  │
  ▼
Implementation
  │
  ▼
PR
  │
  ▼
Independent CI
  │
  ├── Build
  ├── Test
  ├── Security
  ├── API
  └── Scope
  │
  ▼
Gate
  │
  ▼
Human / Merge
```

Claude can **observe** the gates and react to failures.

It shouldn't **control** the gates.

---

### 12. This enables an autonomous repair loop

Now you get something really interesting.

```
                  Claude
                    │
                 implement
                    │
                    ▼
                    PR
                    │
                    ▼
               Quality Gates
                    │
             ┌──────┴──────┐
             │             │
           PASS           FAIL
             │             │
             ▼             ▼
          Review       Feedback
             │             │
             │             ▼
             │          Claude
             │             │
             │          fix
             │             │
             │             └──────┐
             │                    │
             └────────────────────┘
                         │
                         ▼
                    Quality Gates
```

You can allow this automatically:

```
max_retries: 3
```

So:

```
Implementation
→ tests fail
→ Claude investigates
→ fixes
→ tests
→ fail
→ fixes
→ tests
→ PASS
→ human review
```

**That is the beginning of the Software Factory.**

---

### 13. I'd actually separate Gate types

I'd use something like:

```yaml
# .factory/gates.yaml

gates:

  deterministic:
    - build
    - unit-tests
    - integration-tests
    - format
    - analyzers
    - api-compatibility
    - scope
    - security

  ai:
    - acceptance-criteria
    - architecture-review
    - code-review

  human:
    - architecture-approval
    - release-approval
```

Then your state machine knows:

```
IMPLEMENTATION
      ↓
DETERMINISTIC GATES
      ↓
AI REVIEW
      ↓
HUMAN GATE
      ↓
MERGE
```

This gives you a very clean separation of responsibilities.

---

### 14. And I'd make gate results artifacts

Don't just print:

```
Tests passed.
```

Generate:

```
.factory/results/
    build.json
    tests.json
    format.json
    api.json
    scope.json
    acceptance.json
    summary.json
```

Example:

```json
{
  "run_id": "2026-08-18-00142",
  "commit": "abc123",
  "result": "passed",
  "gates": [
    {
      "name": "build",
      "type": "deterministic",
      "result": "passed",
      "duration_ms": 18342
    },
    {
      "name": "tests",
      "type": "deterministic",
      "result": "passed",
      "tests": 142
    },
    {
      "name": "acceptance",
      "type": "ai",
      "result": "passed"
    }
  ]
}
```

Now your factory has **evidence**.

That becomes incredibly useful later for metrics:

```
feature
  ↓
agent
  ↓
implementation
  ↓
gate results
  ↓
review iterations
  ↓
production incidents
```

You can eventually measure:

* first-pass success rate
* average repair iterations
* agent effectiveness
* escaped defects
* time from issue → merge
* cost per feature
* gate failure distribution

---

### The architecture I'd use for your case

Given your existing **Issue → Spec → Implementation Plan → Copilot/Claude → HITL → Test → Feedback → Release** process, I'd start with this:

```
                 GitHub Issue
                       │
                       ▼
              ┌────────────────┐
              │ Contract YAML  │
              │ Spec + Plan    │
              └───────┬────────┘
                      │
                      ▼
                 Claude Code
                      │
                      ▼
                     PR
                      │
              ┌───────▼────────┐
              │  Gate Runner    │
              └───────┬────────┘
                      │
       ┌──────────────┼──────────────┐
       ▼              ▼              ▼
     Build          Tests       API/Scope
       │              │              │
       └──────────────┼──────────────┘
                      ▼
                 AI Review
                      │
                      ▼
                 ┌─────────┐
                 │  HITL   │
                 └────┬────┘
                      ▼
                    MERGE
                      │
                      ▼
                   RELEASE
```

**The first concrete thing I'd implement is therefore not another Claude prompt.**

I'd build:

1. `.factory/contracts/feature.yaml`
2. `.factory/gates.yaml`
3. `.factory/run-gates.ps1`
4. GitHub Actions workflow calling `run-gates.ps1`
5. Branch protection requiring the gate job
6. Claude instructed to read the contract and use the gate runner
7. Later: machine-readable gate results + automatic repair loop

That gives you a solid foundation on which you can add the **Router / Control Plane** later without having to redesign your SDLC.
