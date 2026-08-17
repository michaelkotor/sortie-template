---
# Stage 2 of 3 — building. Sits between WORKFLOW.plan.md and WORKFLOW.review.md. This is the
# highest-volume stage, so it runs on OpenCode's free opencode/deepseek-v4-flash-free — no
# key needed. Planning and review run on Claude Code (claude-opus-5) instead; see
# WORKFLOW.plan.md.
#
# Label an issue `plan-approved` — or let the planning stage self-approve one — and the
# agent implements the plan it posted earlier, verifies it, pushes a branch, and opens a
# pull request.
#
# It then decides whether that pull request needs reviewing. Most do, and the issue is
# handed to the review stage labelled `needs-code-review`. A diff that clears every
# criterion in prompts/build.md skips it: the agent says so on the PR, writes `blocked` to
# suppress the handoff below, and sets `agent-review` itself, leaving the PR waiting on you
# to merge. Add `needs-human` to an issue, or set SORTIE_AUTO_SKIP_REVIEW=off, and every PR
# is reviewed.
#
# This stage runs a second time when the reviewer sends a PR back: the issue arrives
# carrying `plan-approved` again, the branch and PR already exist, and the prompt takes its
# revision path instead of opening a new one.
#
# See WORKFLOW.plan.md for why the stages are separate files.

tracker:
  kind: github
  api_key: $SORTIE_GITHUB_TOKEN
  project: $SORTIE_REPO

  query_filter: "label:plan-approved,agent-building"

  # Dispatching swaps `plan-approved` for `agent-building`. See WORKFLOW.plan.md for why
  # the in-progress label has to appear in both the query and active_states.
  active_states: [plan-approved, agent-building]
  in_progress_state: agent-building
  handoff_state: needs-code-review  # replaces the trigger label, waking the review stage;
                                    # suppressed by `blocked` when the agent skips review
  terminal_states: [agent-done]

  comments:
    on_dispatch: false            # the PR is the notification
    on_completion: false
    on_failure: true

polling:
  interval_ms: 60000

dispatch:
  default:
    template: ./prompts/build.md

hooks:
  # Hooks inherit only SORTIE_*-prefixed variables, so the token arrives as
  # SORTIE_GITHUB_TOKEN. The credential helper keeps it out of .git/config: what is stored
  # is a reference to the variable, which git resolves at push time.
  # A full clone, unlike the planning stage: this one branches, pushes, and on a revision
  # pass checks out an existing branch. (On a large repository, point SORTIE_REPO_URL at a
  # local mirror rather than trading this for a shallow clone.)
  after_create: |
    git clone "$SORTIE_REPO_URL" .
    git config user.name  "sortie agent"
    git config user.email "agent@users.noreply.github.com"
    git config credential.helper '!f() { printf "username=x-access-token\npassword=%s\n" "$SORTIE_GITHUB_TOKEN"; }; f'

    # Agent context from your working copy that the remote does not have yet. See the same
    # block in WORKFLOW.plan.md — untracked files only, and excluded from git, so seeding
    # can never put config into the pull request this stage opens.
    for f in config/sortie/AUTONOMY.md AGENTS.md; do
      [ -f "$SORTIE_PROJECT_DIR/$f" ] || continue
      git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
      mkdir -p "$(dirname "$f")"
      cp "$SORTIE_PROJECT_DIR/$f" "$f"
      grep -qxF "$f" .git/info/exclude 2>/dev/null || printf '%s\n' "$f" >> .git/info/exclude
    done

  # Work on a branch is expected and left alone. A dirty default branch means the agent
  # never branched, so keep the diff for inspection and reset.
  after_run: |
    default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
    [ -n "$default" ] || default=main
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)
    if [ "$branch" = "$default" ] && [ -n "$(git status --porcelain -- . ':!.sortie')" ]; then
      git diff > .sortie/unexpected.diff 2>/dev/null || true
      git reset --hard >/dev/null 2>&1 || true
      git clean -fd -e .sortie >/dev/null 2>&1 || true
      echo "warning: agent modified $default without opening a branch" >&2
    fi
  timeout_ms: 120000

agent:
  kind: opencode
  command: opencode
  max_turns: 8                    # implement, verify, fix, push, open the PR
  max_concurrent_agents: 1
  turn_timeout_ms: 1800000        # 30 min
  stall_timeout_ms: 300000

opencode:
  dangerously_skip_permissions: true
  model: opencode/deepseek-v4-flash-free  # free OpenCode Zen model; runs without a key
---

The prompt for this stage is `config/sortie/prompts/build.md`. This body is the fallback
template and is not used.
