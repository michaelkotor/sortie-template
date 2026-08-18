---
# Stage 1 of 3 — planning. Followed by WORKFLOW.build.md and WORKFLOW.review.md. Planning and
# review run on Claude Code (claude-opus-5) — the two passes where judgement matters most.
# Building runs on OpenCode's free deepseek-v4-flash-free instead; see WORKFLOW.build.md.
#
# Label an issue `agent-plan` and the agent reads it, works out how it fits the codebase,
# and posts an implementation plan as a comment. It writes nothing and pushes nothing.
#
# The agent then decides whether that plan needs a human. Most do: the issue comes back to
# you labelled `agent-review`, for you to approve with `plan-approved` or to send back for
# another plan. A small, unambiguous ticket that clears every criterion in prompts/plan.md
# it self-approves instead — it writes `blocked` to suppress the handoff below and sets
# `plan-approved` itself, so the build stage picks it up on the next poll. Add `needs-human`
# to an issue, or set SORTIE_AUTO_APPROVE_PLANS=off, and it always asks.
#
# The stages are separate files because Sortie's dispatch rules can override the agent kind
# and the prompt template per rule, but not adapter config — so a per-stage model means a
# per-stage process. Run all three with scripts/sortie.sh, which sets $SORTIE_REPO from the
# git remote and gives each stage its own database, workspace root, and port.

tracker:
  kind: github
  api_key: $SORTIE_GITHUB_TOKEN
  project: $SORTIE_REPO

  query_filter: "label:agent-plan,agent-planning"   # GitHub search: this label or that one

  # GitHub has no workflow states, so Sortie maps states onto labels. They must already
  # exist in the repo — Sortie does not create them. scripts/sortie.sh does.
  #
  # A transition removes the current state label before adding the new one, so dispatching
  # swaps `agent-plan` for `agent-planning` rather than adding to it — which is what makes
  # the issue say, at a glance, that an agent has it. Two consequences, and both are
  # load-bearing: `agent-planning` has to be in active_states, or reconciliation cancels
  # the worker it just transitioned, and it has to be in query_filter, or the issue drops
  # out of the candidate query the moment the transition lands. The stages stay disjoint
  # because no other stage queries either label.
  active_states: [agent-plan, agent-planning]
  in_progress_state: agent-planning
  handoff_state: agent-review     # replaces the trigger label when the plan needs a human;
                                  # suppressed by a `blocked` status when it self-approves
  terminal_states: [agent-done]

  comments:
    on_dispatch: false            # the agent posts its own
    on_completion: false
    on_failure: true              # do tell us when a run dies

polling:
  interval_ms: 60000

dispatch:
  default:
    template: ./prompts/plan.md

hooks:
  # Hooks inherit only SORTIE_*-prefixed variables. No git identity and no credential
  # helper here, unlike the build stage: planning has nothing to commit, so this process is
  # left with no way to push at all.
  after_create: |
    git clone --depth 1 "$SORTIE_REPO_URL" .

    # The workspace is a clone of the remote, so a file you have written but not pushed is
    # invisible to the agent — including config/sortie/AUTONOMY.md, which the autonomy gate
    # is required to read. Carry those over from the working copy instead of making you
    # commit first. Only files the clone does not track are copied, so nothing overwrites
    # the repository's own version, and each is added to .git/info/exclude so it can never
    # reach a commit or a pull request.
    for f in config/sortie/AUTONOMY.md AGENTS.md; do
      [ -f "$SORTIE_PROJECT_DIR/$f" ] || continue
      git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
      mkdir -p "$(dirname "$f")"
      cp "$SORTIE_PROJECT_DIR/$f" "$f"
      grep -qxF "$f" .git/info/exclude 2>/dev/null || printf '%s\n' "$f" >> .git/info/exclude
    done

  # A planning run must leave the tree alone. If it did not, keep the diff and reset.
  after_run: |
    if [ -n "$(git status --porcelain -- . ':!.sortie')" ]; then
      git diff > .sortie/unexpected.diff 2>/dev/null || true
      git reset --hard >/dev/null 2>&1 || true
      git clean -fd -e .sortie >/dev/null 2>&1 || true
      echo "warning: agent modified the workspace during a plan-only run" >&2
    fi
  timeout_ms: 120000

agent:
  kind: claude-code
  command: claude
  max_turns: 1                    # read, plan, comment, stop
  max_concurrent_agents: 1
  turn_timeout_ms: 1800000        # 30 min
  stall_timeout_ms: 300000        # 5 min of silence = stalled
  read_timeout_ms: 120000         # wait for the agent's first event; a cold start can outlast
                                  # the 5s default, which fails as `response_timeout`
  max_sessions: 10                # give up after ten failed runs, not retry forever
  max_retry_backoff_ms: 1800000   # 30 min cap — waits double per failed run, 10s → … → 160s → 320s → … → 30m

claude-code:
  permission_mode: bypassPermissions  # required headless; the workspace is disposable
  model: claude-opus-5                # planning is the part worth the better model
  max_turns: 60                       # Claude Code's own internal turn budget
---

The prompt for this stage is `config/sortie/prompts/plan.md`. This body is the fallback
template and is not used.
