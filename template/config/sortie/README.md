# The automated issue workflow

Labelled issues are handled by OpenCode through [Sortie](https://github.com/sortie-ai/sortie),
in four stages, each its own process. Three of them form the plan → build → review line; the
fourth, system design, is a separate track that analyses a ticket without ever building it.
`../../scripts/sortie.sh run` starts them; nothing happens to an issue that carries no label.

This file is installed by the template and refreshed when it is upgraded, so it stays
accurate without anyone editing `AGENTS.md`. The one part that is yours to write lives in
[`AUTONOMY.md`](AUTONOMY.md), which is never overwritten.

## The stages

| Label | What happens | Where it goes |
| --- | --- | --- |
| `agent-plan` | reads the issue and the code, comments an implementation plan | `agent-review` for you to approve — or straight to `plan-approved`, if the planner judged the ticket small and unambiguous |
| `plan-approved` | implements that plan, verifies it, pushes a branch, opens a PR | `needs-code-review` — or straight to `agent-review`, if the diff was trivial and verified |
| `needs-code-review` | a second agent re-runs the verification and reads the diff against the plan | `agent-review` when it approves, `plan-approved` for another build round, at most twice |
| `system-design` | reads the issue and the code, comments a design analysis: the problem, the options, and whether it is worth doing at all. Runs on Claude Opus — the one paid stage — and never implements anything | `agent-review` for you to read; if you decide to proceed, label `agent-plan` yourself |

`agent-review` means the issue is waiting on a human. `agent-done` releases the agent's
claim on it.

While a stage is working, the issue says so: dispatch replaces the trigger label with
`agent-planning`, `agent-building`, `agent-reviewing`, or `agent-designing` for as long as
that agent runs. An issue sitting in one of those for an hour is a run that died, not a run
in progress.

## The shortcuts, and how to stop them

Each stage decides whether the step after it is worth a human's time, and says on the issue
which way it went and why. The planner self-approves only a ticket with no open questions,
effort S, confined to files it names, in an area with tests and verification commands
behind it. The builder skips the review only for a small diff — roughly three files and
fifty changed lines — that passed every applicable verification command and did exactly
what the plan said. A revision never skips review.

Neither gate opens for authentication, permissions, secrets, money, migrations or anything
that rewrites stored data, a public interface changing shape, a dependency changing, CI or
deployment config, concurrency, or a ticket that asks for a decision rather than a defined
change. Nor for anything listed in [`AUTONOMY.md`](AUTONOMY.md). An unclear case is a
human's case.

To turn a shortcut off:

- label an issue `needs-human` — that issue gets neither shortcut
- set `SORTIE_AUTO_APPROVE_PLANS=off` or `SORTIE_AUTO_SKIP_REVIEW=off` in `.env` — that
  shortcut is off everywhere

## The files here

```
WORKFLOW.plan.md    stage 1: plan, read-only, one turn
WORKFLOW.build.md   stage 2: build, branches and pushes
WORKFLOW.review.md  stage 3: review, verifies and judges the PR
WORKFLOW.design.md  separate track: design analysis, read-only, runs on Opus
prompts/*.md        what each stage is told
AUTONOMY.md         what this project never lets an agent decide alone — yours to write
env.example         the token, the switches, and where to get them
.env                your copy of it. Never committed, never touched by the installer.
```

The prompts read `AGENTS.md` in the repository root for the project's constraints, layout,
and — this is the load-bearing one — the exact commands that verify a change.
