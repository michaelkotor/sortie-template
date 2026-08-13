---
# Stage 3 of 3 — reviewing, on Opus. Runs on the pull request the build stage opened, when
# the build stage judged that it needs reviewing at all — a trivial diff is sent straight to
# you instead, and this stage never sees it.
#
# The build stage hands the issue over labelled `needs-code-review`. This stage checks out
# the PR branch, re-runs the project's own verification commands, reads the diff against
# the approved plan, and takes one of two exits:
#
#   minor issues only  →  posts an approving review, hands the issue to `agent-review`
#                         for you to merge
#   blocking issues    →  posts what to change, relabels the issue `plan-approved` itself,
#                         and the build stage picks it up as a revision
#
# The second exit is why the prompt does its own label surgery: writing `blocked` to
# `.sortie/status` suppresses the handoff transition, leaving the agent free to set the
# label the next stage needs. See prompts/review.md.

tracker:
  kind: github
  api_key: $SORTIE_GITHUB_TOKEN
  project: $SORTIE_REPO

  query_filter: "label:needs-code-review,agent-reviewing"

  # Dispatching swaps `needs-code-review` for `agent-reviewing`. See WORKFLOW.plan.md for
  # why the in-progress label has to appear in both the query and active_states.
  active_states: [needs-code-review, agent-reviewing]
  in_progress_state: agent-reviewing
  handoff_state: agent-review     # applied only on the approving exit
  terminal_states: [agent-done]

  comments:
    on_dispatch: false
    on_completion: false
    on_failure: true

polling:
  interval_ms: 60000

dispatch:
  default:
    template: ./prompts/review.md

hooks:
  # A full clone: the reviewer needs history and the base branch to make sense of a diff.
  after_create: |
    git clone "$SORTIE_REPO_URL" .

  # The PR branch is fetched here rather than by the agent, so the credential helper can be
  # removed again before the agent runs. The reviewer therefore has the code but no way to
  # push it — the same shape as the planning stage.
  #
  # A missing branch is not fatal: the agent reports it and stops, which is more useful
  # than a hook failure that retries with backoff.
  before_run: |
    git config credential.helper '!f() { printf "username=x-access-token\npassword=%s\n" "$SORTIE_GITHUB_TOKEN"; }; f'
    git fetch origin "sortie/issue-$SORTIE_ISSUE_IDENTIFIER" 2>/dev/null \
      && git checkout -q FETCH_HEAD || echo "warning: no branch sortie/issue-$SORTIE_ISSUE_IDENTIFIER" >&2
    git config --unset credential.helper || true

    # Agent context from your working copy that the remote does not have yet — after the
    # checkout, so the PR branch decides what the code is and only unpushed files are added.
    # See the same block in WORKFLOW.plan.md.
    for f in config/sortie/AUTONOMY.md AGENTS.md; do
      [ -f "$SORTIE_PROJECT_DIR/$f" ] || continue
      git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
      mkdir -p "$(dirname "$f")"
      cp "$SORTIE_PROJECT_DIR/$f" "$f"
      grep -qxF "$f" .git/info/exclude 2>/dev/null || printf '%s\n' "$f" >> .git/info/exclude
    done

  after_run: |
    if [ -n "$(git status --porcelain -- . ':!.sortie')" ]; then
      git diff > .sortie/unexpected.diff 2>/dev/null || true
      git reset --hard >/dev/null 2>&1 || true
      git clean -fd -e .sortie >/dev/null 2>&1 || true
      echo "warning: agent modified the workspace during a review-only run" >&2
    fi
  timeout_ms: 300000

agent:
  kind: claude-code
  command: claude
  max_turns: 1                    # verify, judge, post, route the label
  max_concurrent_agents: 1
  turn_timeout_ms: 1800000
  stall_timeout_ms: 300000

claude-code:
  permission_mode: bypassPermissions
  model: claude-opus-5            # the reviewer should be at least as strong as the planner
  max_turns: 60
---

The prompt for this stage is `config/sortie/prompts/review.md`. This body is the fallback
template and is not used.
