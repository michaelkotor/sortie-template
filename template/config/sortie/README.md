# The automated issue workflow

Labelled issues are handled by [Sortie](https://github.com/sortie-ai/sortie), in four stages,
each its own process. Three of them form the plan → build → review line; the fourth, system
design, is a separate track that analyses a ticket without ever building it. Plan, review,
and design run on Claude Code (Opus); building runs on OpenCode's free DeepSeek model.
`../../scripts/sortie.sh run` starts all four; nothing happens to an issue that carries no
label.

If Claude Code itself is down or unreachable, Sortie retries whichever of plan, review, or
design hit it with backoff rather than switching to a different tool — Sortie has no
cross-adapter fallback, so a stuck run stays on `claude-code` until it recovers.

This file is installed by the template and refreshed when it is upgraded, so it stays
accurate without anyone editing `AGENTS.md`. The one part that is yours to write lives in
[`AUTONOMY.md`](AUTONOMY.md), which is never overwritten.

## The stages

| Label | What happens | Where it goes |
| --- | --- | --- |
| `agent-plan` | reads the issue and the code, comments an implementation plan | `agent-review` for you to approve — or straight to `plan-approved`, if the planner judged the ticket small and unambiguous |
| `plan-approved` | implements that plan, verifies it, pushes a branch, opens a PR | `needs-code-review` — or straight to `agent-review`, if the diff was trivial and verified |
| `needs-code-review` | a second agent re-runs the verification and reads the diff against the plan | `agent-review` when it approves, `plan-approved` for another build round, at most twice |
| `system-design` | reads the issue and the code, comments a design analysis: the problem, the options, and whether it is worth doing at all. Runs on Claude Code, like plan and review, and never implements anything | `agent-review` for you to read; if you decide to proceed, label `agent-plan` yourself |

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

## Picking up changes

Each stage loads its workflow once at startup, so a merge to the code they run is not
live until the stages restart. With `SORTIE_AUTO_UPDATE=on` in `.env` (off by default),
`sortie.sh run` pulls the default branch every `SORTIE_AUTO_UPDATE_INTERVAL` seconds
(default 300), fast-forwards when the tree is clean and HEAD is already on the default
branch, re-runs `./install.sh --force` when this repo was itself installed from the
template (the installed copies under `config/sortie/` and `scripts/` are only refreshed by
the installer), and restarts the stages. It never pulls onto a dirty tree or a non-default
branch, and never restarts while an issue is mid-run — a restart would kill the agent
working it. To stop auto-update, set `SORTIE_AUTO_UPDATE=off`.

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
