---
# A separate track, not stage 0 of the plan → build → review line — system design. Label an
# issue `system-design` and the agent reads it and the code and posts an analysis: what is
# actually being asked, the options, and whether it is worth doing at all. It writes
# nothing, implements nothing, and never starts work on its own — the analysis comes back
# to you labelled `agent-review`, and chaining it into a plan is your call.
#
# This is the one stage that does not run free. The other three run
# opencode/deepseek-v4-flash-free, the free OpenCode Zen DeepSeek model that needs no API
# key. Design runs on Anthropic's Opus instead — thinking is the deliverable, so it is told
# to read more and given long timeouts, and it bills real money. It needs a Claude Code
# sign-in on the machine running the stage (see env.example), which for this stage is on
# PATH as `claude` in addition to `sortie`, `gh`, and `opencode`. The cost caps below are
# the only thing between a runaway run and a real bill.
#
# The stages are separate files because Sortie's dispatch rules can override the agent kind
# and the prompt template per rule, but not adapter config — so a per-stage model means a
# per-stage process. Run it with scripts/sortie.sh, which sets $SORTIE_REPO from the git
# remote and gives the stage its own database, workspace root, and port.

tracker:
  kind: github
  api_key: $SORTIE_GITHUB_TOKEN
  project: $SORTIE_REPO

  query_filter: "label:system-design,agent-designing"   # GitHub search: this label or that one

  # Two labels, not one, for the same load-bearing reason as every other stage: the
  # in-progress label must appear in both query_filter and active_states, or reconciliation
  # cancels the worker it just dispatched. See WORKFLOW.plan.md's comments.
  active_states: [system-design, agent-designing]
  in_progress_state: agent-designing
  handoff_state: agent-review     # the analysis is for a human to read
  terminal_states: [agent-done]

  comments:
    on_dispatch: false            # the agent posts its own
    on_completion: false
    on_failure: true              # do tell us when a run dies

polling:
  interval_ms: 60000

dispatch:
  default:
    template: ./prompts/design.md

hooks:
  # Hooks inherit only SORTIE_*-prefixed variables. No git identity and no credential
  # helper: design has nothing to commit, so this process is left with no way to push at
  # all.
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

  # A design run must leave the tree alone. If it did not, keep the diff and reset.
  after_run: |
    if [ -n "$(git status --porcelain -- . ':!.sortie')" ]; then
      git diff > .sortie/unexpected.diff 2>/dev/null || true
      git reset --hard >/dev/null 2>&1 || true
      git clean -fd -e .sortie >/dev/null 2>&1 || true
      echo "warning: agent modified the workspace during a design-only run" >&2
    fi
  timeout_ms: 120000

agent:
  kind: claude-code
  command: claude
  max_turns: 3                    # read widely, then write and post — more than planning's 1
  max_concurrent_agents: 1
  turn_timeout_ms: 3600000        # 1 h — thinking is the deliverable, so it is allowed to be expensive
  stall_timeout_ms: 600000        # 10 min of silence = stalled
  max_sessions: 10                # give up after ten failed runs, not retry forever
  max_retry_backoff_ms: 1800000   # 30 min cap — waits double per failed run, 10s → … → 160s → 320s → … → 30m

claude-code:
  dangerously_skip_permissions: true  # required headless; the workspace is disposable
  model: opus                         # paid Anthropic model; needs a Claude Code sign-in
---

The prompt for this stage is `config/sortie/prompts/design.md`. This body is the fallback
template and is not used.
