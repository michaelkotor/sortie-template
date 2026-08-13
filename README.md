# sortie-template

A three-stage GitHub issue → reviewed pull request setup for
[Sortie](https://github.com/sortie-ai/sortie), driving Claude Code on your own machine.
Drop it into any repository.

```bash
~/IdeaProjects/sortie-template/install.sh /path/to/your/repo
```

## What it does

You label an issue and an agent picks it up. Nothing happens without a label, and nothing
merges without you.

| You do | The agent does | You get back |
| --- | --- | --- |
| label `agent-plan` | reads the issue and the code, posts an implementation plan | issue relabelled `agent-review`, plan in a comment |
| label `plan-approved` | implements that plan, verifies it, pushes a branch, opens a PR | issue relabelled `needs-code-review`, which wakes the reviewer |
| *(nothing — automatic)* | a second agent re-runs your verification commands and reads the diff against the plan | either an approving review and `agent-review` for you to merge, or a list of what to change and another build round |

Reply on the issue before approving and your comment is folded in as an additional
requirement — it adds to the plan rather than replacing it. Re-add `agent-plan` for a
fresh plan instead.

While a stage is working, the issue says so. Dispatch replaces the trigger label with
`agent-planning`, `agent-building`, or `agent-reviewing`, and the stage puts the next label
on when it finishes — so a label is never just "queued or running, no way to tell", and an
issue that has sat in `agent-building` for an hour is a run that died.

## The steps it skips

That is the full route. Small work does not take it: each stage decides whether the step
after it is worth a human's time, and says on the issue which way it went and why.

The **planner** self-approves when the ticket is small and has exactly one sensible
implementation — no open questions, effort S, confined to files it names, an area with
tests and verification commands behind it. It sets `plan-approved` itself and the build
stage starts on the next poll. You still get the plan as a comment, and you can pull the
label off before then.

The **builder** skips the review when the diff is small (roughly three files, fifty lines),
every verification command that applies passed, and the change does what the plan said and
nothing more. The pull request comes straight back as `agent-review` with the verification
output on it.

Neither gate ever opens for authentication, permissions, secrets, money, migrations or
anything that rewrites stored data, a public interface changing shape, a dependency
changing, CI or deployment config, concurrency, or a ticket that asks for a decision rather
than a defined change. Both prompts carry that list, and both are told that an unclear case
is a human's case. A revision never skips review either — a reviewer already found
something wrong in that branch.

Two ways to turn it off: label an issue `needs-human` and both gates close for that issue,
or set `SORTIE_AUTO_APPROVE_PLANS=off` / `SORTIE_AUTO_SKIP_REVIEW=off` in
`config/sortie/.env` to close one everywhere. A project can also name its own always-ask
cases in `AGENTS.md`; both prompts read it.

## The review loop

Every stage routes its own outcome — the reviewer routes two of them. Nothing blocking, and
it approves the PR and hands the issue to you. Something blocking, and it writes what to
change, relabels the issue `plan-approved` itself, and the build stage picks it up as a
revision — same branch, same PR, no second one opened.

That loop is capped at two rounds. On the third it escalates to you instead, on the
principle that a human reads faster than another cycle.

Two things to know about it. GitHub refuses to let an account approve its own pull request,
and every stage shares one token, so "approve" is a review comment with an explicit verdict
unless you give the reviewer its own account. And the reviewer *runs* your verification
commands rather than trusting the PR body — a PR claiming green checks that do not
reproduce is itself a blocking finding.

## Why three processes

Planning and review run on Opus, building on Sonnet. Sortie's dispatch rules can override
the agent kind and the prompt template per rule, but not adapter config, so a per-stage
model means a per-stage process. `scripts/sortie.sh run` starts all three, gives each its
own database, workspace root, and port, and stops them together on Ctrl-C. Their label
queries are disjoint, so none can pick up another's issues.

## What gets installed

```
config/sortie/WORKFLOW.plan.md    stage 1: Opus, read-only, one turn
config/sortie/WORKFLOW.build.md   stage 2: Sonnet, branches and pushes
config/sortie/WORKFLOW.review.md  stage 3: Opus, verifies and judges the PR
config/sortie/prompts/*.md        what each stage is told
config/sortie/README.md           how the pipeline works, for whoever reads the repo
config/sortie/AUTONOMY.md         what a human must decide here — written once, never again
config/sortie/env.example         the token, the switches, and where to get them
scripts/sortie.sh                 setup / check / run / stats
AGENTS.md                         skeleton, only if the project has none
```

`AGENTS.md` gets one line out of all this: a pointer to `config/sortie/README.md`, appended
once if it is missing. The workflow is described in exactly one place, so upgrading the
template never means re-editing a file the agents treat as binding — and `AUTONOMY.md`,
the half that is yours to write, is never overwritten either.

Nothing is substituted at install time. The workflows read `$SORTIE_REPO`, which
`scripts/sortie.sh` derives from the git remote, and the prompts let `gh` resolve the
repository from the clone — so the same files work in every project.

## AGENTS.md is the part you write

The prompts are deliberately generic. Everything project-specific lives in `AGENTS.md`:
the constraints that are load-bearing, where the code lives, and **the exact commands that
verify a change** — the build stage runs the ones that apply to what it touched and will
not commit until they pass, and the reviewer runs them again independently. A thin
`AGENTS.md` gives you thin plans, unverified PRs, and a reviewer with nothing to check
against.

## Safety

- **Opt-in per issue.** Every stage queries on a trigger label; an unlabelled issue is never
  touched.
- **The gates fail towards you.** An agent that cannot tell whether a plan or a diff needs a
  human is told to decide that it does, and `needs-human` on the issue removes the choice.
- **Least privilege.** A fine-grained token scoped to one repository. Keep Contents at
  read-only and the planning stage still works while the agent cannot push at all.
- **Neither the planning nor the review process can push.** Planning gets no git identity
  and no credential helper at all; review borrows one to fetch the PR branch in a hook and
  gives it up again before the agent starts.
- **The reviewer did not write the code.** It reads the diff against the plan with no stake
  in it being right, and re-runs the verification itself.
- **Disposable workspaces.** Each issue gets its own clone under `~/.sortie/<owner>-<repo>/`.
- **The token is never written to disk.** The build stage stores a git credential helper
  that references `$SORTIE_GITHUB_TOKEN` and resolves it at push time.
- **A planning run that edits the tree is reverted**, with the diff kept at
  `.sortie/unexpected.diff` in the workspace.
- **You merge.** The agent opens the PR and stops.

## Requirements

`sortie`, `gh`, and `claude` on PATH, and a `claude` you are signed in to (or
`ANTHROPIC_API_KEY` set, if you would rather bill the API).
