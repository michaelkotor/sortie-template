#!/bin/bash
# sortie - turn GitHub issues into plans, and approved plans into pull requests.
#
#   ./scripts/sortie.sh setup                      create the labels, check credentials
#   ./scripts/sortie.sh check                      validate and poll once, changing nothing
#   ./scripts/sortie.sh run                        run all four stages (Ctrl-C stops them)
#   ./scripts/sortie.sh run plan|build|review|design run one stage on its own
#   ./scripts/sortie.sh stats [stage]              summarise past runs
#
# Label an issue `agent-plan` and the agent comments an implementation plan. Approve it by
# labelling `plan-approved` and the agent implements it and opens a PR. A reviewer then
# checks that PR: clean work is approved and comes back to you as `agent-review`, and work
# with blocking problems goes round again as `plan-approved`, capped at two rounds.
#
# Each stage may also skip the step after it when the work is small enough not to warrant
# one: the planner self-approves a plan it judges trivial and unambiguous, and the builder
# sends a trivial diff straight to you rather than to the reviewer. Both say so on the
# issue. Label an issue `needs-human` to disable both gates for it, or set
# SORTIE_AUTO_APPROVE_PLANS=off / SORTIE_AUTO_SKIP_REVIEW=off in config/sortie/.env to
# disable them everywhere.
#
# The stages are four Sortie processes because Sortie has no per-dispatch-rule model
# setting, and the stages are meant to be able to run different models. Plan and design run
# on Claude Code (claude-opus-5) — the passes where judgement matters most. Building and
# review run on opencode/deepseek-v4-flash-free, the free OpenCode Zen DeepSeek model,
# since they are the volume stages and doing them for free is the point. They keep
# separate databases, workspaces, and ports, and their label queries are disjoint, so none
# can pick up another's issues.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 3

ENV_FILE=config/sortie/.env
STAGES=(plan build review design)
# Sortie's own log verbosity: debug, info, warn, error. Previous runs kept an opaque
# `turn_failed` even when opencode's error was a mask over something actionable — sortie
# recovers the real reason ("Model not found: ...", rate limit, auth) only at debug level.
# So this defaults to debug: failures get to explain themselves. If the once-a-minute poll
# chatter from four processes bothers you, SORTIE_LOG_LEVEL=warn keeps failures and
# retries and nothing else. It does not touch what the agents themselves print.
LOG_LEVEL=${SORTIE_LOG_LEVEL:-debug}
PLAN_PORT=${SORTIE_PLAN_PORT:-7678}
BUILD_PORT=${SORTIE_BUILD_PORT:-7679}
REVIEW_PORT=${SORTIE_REVIEW_PORT:-7680}
DESIGN_PORT=${SORTIE_DESIGN_PORT:-7681}

workflow_for() { printf 'config/sortie/WORKFLOW.%s.md' "$1"; }
port_for()     { case $1 in plan) printf '%s' "$PLAN_PORT" ;; build) printf '%s' "$BUILD_PORT" ;; review) printf '%s' "$REVIEW_PORT" ;; design) printf '%s' "$DESIGN_PORT" ;; esac; }
trigger_for()  { case $1 in plan) printf 'agent-plan' ;; build) printf 'plan-approved' ;; review) printf 'needs-code-review' ;; design) printf 'system-design' ;; esac; }

die() { printf 'sortie: %s\n' "$1" >&2; exit 1; }

# --------------------------------------------------------------------------- environment
#
# Sortie's hooks only inherit SORTIE_*-prefixed variables, and the agent subprocess
# (opencode or claude, depending on the stage) inherits whatever this process holds. So
# everything is exported here rather than handed to `sortie --env-file`, which feeds config
# overrides only and not the agent's shell.

# owner/repo, from SORTIE_REPO if set, otherwise from the git remote.
detect_repo() {
    [[ -z ${SORTIE_REPO:-} ]] || { printf '%s' "$SORTIE_REPO"; return; }
    local url
    url=$(git config --get remote.origin.url 2>/dev/null)
    [[ -n $url ]] || die "no git remote 'origin' — set SORTIE_REPO=owner/repo in $ENV_FILE"
    url=${url%.git}
    case $url in
        *://*)   printf '%s' "${url#*://*/}" ;;   # https://host/owner/repo
        *:*)     printf '%s' "${url##*:}"    ;;   # git@host:owner/repo
        *)       die "cannot parse remote origin url: $url" ;;
    esac
}

load_env() {
    [[ -f $ENV_FILE ]] || die "missing $ENV_FILE — copy config/sortie/env.example and fill it in"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" || die "could not read $ENV_FILE"
    set +a

    # Auto-update is read here rather than beside LOG_LEVEL at the top of the script: .env
    # is only sourced by load_env, and the top-of-file reads run before it. A read there
    # would never see the switch. Defaults off — pulling and executing newly merged code
    # on a working copy is opt-in.
    AUTO_UPDATE=${SORTIE_AUTO_UPDATE:-off}
    AUTO_UPDATE_INTERVAL=${SORTIE_AUTO_UPDATE_INTERVAL:-300}
    [[ $AUTO_UPDATE_INTERVAL =~ ^[0-9]+$ ]] || AUTO_UPDATE_INTERVAL=300

    [[ -n ${SORTIE_GITHUB_TOKEN:-} ]] || die "SORTIE_GITHUB_TOKEN is empty in $ENV_FILE"

    # Where this project actually lives on disk. The agents work in clones of the remote,
    # so the hooks use this to carry over agent context you have not pushed yet — see the
    # after_create hook in any WORKFLOW file. SORTIE_-prefixed because hooks inherit
    # nothing else.
    export SORTIE_PROJECT_DIR="$PWD"

    REPO=$(detect_repo) || exit 1
    [[ $REPO == */* ]] || die "SORTIE_REPO must be owner/repo, got '$REPO'"
    export SORTIE_REPO="$REPO"
    export SORTIE_REPO_URL="${SORTIE_REPO_URL:-https://github.com/$REPO.git}"

    # The agent posts its comment with `gh`, which reads GH_TOKEN.
    export GH_TOKEN="$SORTIE_GITHUB_TOKEN"

    # State is keyed by repository, so several projects can run side by side.
    STATE_DIR="$HOME/.sortie/${REPO//\//-}"
    mkdir -p "$STATE_DIR" || die "could not create $STATE_DIR"
}

# Each stage gets its own database and workspace root, so the two processes never contend.
# These are Sortie's own env overrides, applied per invocation rather than globally.
stage_ws() { printf '%s/workspaces-%s' "$STATE_DIR" "$1"; }
stage_db() { printf '%s/sortie-%s.db' "$STATE_DIR" "$1"; }

stage_env() {
    mkdir -p "$(stage_ws "$1")" || die "could not create $(stage_ws "$1")"
    export SORTIE_WORKSPACE_ROOT="$(stage_ws "$1")"
    export SORTIE_DB_PATH="$(stage_db "$1")"
}

require() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not installed ($2)"
}

# A stage whose port is taken logs one error and exits, leaving the other stages running and
# the pipeline quietly half-connected. Refuse to start instead. Checked with bash's /dev/tcp
# so this needs no lsof or nc.
require_free_port() {
    (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null \
        && die "port $2 (the $1 stage) is already in use — another run is going, or set SORTIE_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_PORT"
    return 0
}

preflight() {
    local stage                     # not optional: bash locals are visible to callees, so
                                    # an undeclared loop variable would clobber the
                                    # caller's variable of the same name
    require sortie 'curl -sSL https://get.sortie-ai.com/install.sh | sh'
    require gh     'brew install gh'
    require claude 'https://claude.com/claude-code'   # plan, design
    require opencode 'https://opencode.ai'             # build, review
    for stage in "${STAGES[@]}"; do
        [[ -f $(workflow_for "$stage") ]] || die "missing $(workflow_for "$stage")"
    done
    load_env
}

# --------------------------------------------------------------------------- labels
#
# Sortie maps its states onto GitHub labels and will not create them itself: a missing label
# does not fail at startup, it fails later as a transition error, mid-run, after the agent
# has already done the work. So every command that talks to the tracker ensures them first.
# Creating a label that exists is a no-op, so this is cheap to repeat.
#
# `needs-human` is the exception: it is not a Sortie state at all, and no workflow queries
# it. The prompts read it themselves, and treat it as an instruction to close both autonomy
# gates for that issue — ask before building, and review before handing back.

ensure_labels() {
    local verbose=${1:-quiet} name color desc
    local specs=(
        'agent-plan|0e8a16|Ask the agent to propose an implementation plan'
        'agent-planning|c2e0c6|A planning agent has this right now'
        'system-design|1d76db|Ask the agent for a design analysis — problem, options, whether it is worth doing'
        'agent-designing|c5def5|A design agent has this right now'
        'plan-approved|0052cc|Plan approved — the agent may implement it and open a PR'
        'agent-building|bfd4f2|A build agent has this right now'
        'needs-code-review|d4c5f9|Pull request open — waiting on the review stage'
        'agent-reviewing|ede4ff|A review agent has this right now'
        'agent-review|fbca04|The agent is done and is waiting on you'
        'agent-done|5319e7|Finished — releases the agent claim'
        'needs-human|b60205|Never decide alone on this one — human approval and a full code review'
    )
    for spec in "${specs[@]}"; do
        IFS='|' read -r name color desc <<< "$spec"
        if gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" >/dev/null 2>&1; then
            printf '  created  %s\n' "$name"
        elif gh api "repos/$REPO/labels/$name" --silent >/dev/null 2>&1; then
            # An exact REST lookup rather than `gh label list --search`: label search is
            # fuzzy and its index lags creation, so a label made seconds earlier can come
            # back missing and abort the run.
            [[ $verbose == verbose ]] && printf '  exists   %s\n' "$name"
        else
            die "could not create label '$name' in $REPO — the token needs Issues: Read and write"
        fi
    done
    return 0
}

# --------------------------------------------------------------------------- setup

setup() {
    local stage
    preflight
    printf 'Repository: %s\n' "$REPO"
    printf 'Checking the token ...\n'
    gh api "repos/$REPO" --silent 2>/dev/null \
        || die "token cannot read $REPO — check it is fine-grained, scoped to that repo, and not expired"

    printf 'Labels ...\n'
    ensure_labels verbose

    printf '\nValidating the workflows ...\n'
    for stage in "${STAGES[@]}"; do
        sortie validate "$(workflow_for "$stage")" || die "$stage workflow did not validate"
        printf '  ok       %s\n' "$(workflow_for "$stage")"
    done

    [[ -f AGENTS.md ]] || printf '\nNote: no AGENTS.md in the repository root. All four prompts read it for\n  project constraints and verification commands. Write one before relying on this.\n'

    cat <<EOF

Ready. Start all four stages with 'run' and leave them going; then, on any issue:

  label 'system-design'   → the agent comments a design analysis — the problem, the options,
                            and whether it is worth doing. It always hands back as
                            'agent-review' for you to read
  label 'agent-plan'      → the agent comments a plan. It hands back as 'agent-review'
                            for you to approve, unless it judges the ticket small and
                            unambiguous enough to self-approve — then it goes straight on
  label 'plan-approved'   → the agent implements it and opens a PR. A trivial diff
                            comes straight back to you as 'agent-review'; anything else goes
                            to the reviewer, which approves it — back to you — or sends it
                            round again, at most twice

  label 'needs-human'     → that issue gets neither shortcut: you approve the plan, and
                            the PR is always reviewed

While a stage has an issue, the issue says so: the trigger label is replaced by
'agent-planning', 'agent-building', 'agent-reviewing', or 'agent-designing' for as long as
that agent runs.

Set SORTIE_AUTO_APPROVE_PLANS=off or SORTIE_AUTO_SKIP_REVIEW=off in $ENV_FILE to turn a
shortcut off everywhere.

Use 'check' first to confirm an issue is picked up without spawning anything.
EOF
}

# --------------------------------------------------------------------------- run

check() {
    local stage
    preflight
    ensure_labels
    for stage in "${STAGES[@]}"; do
        printf '\n=== %s: validate, then poll once (no agents spawned) ===\n' "$stage"
        ( stage_env "$stage"
          sortie validate "$(workflow_for "$stage")" \
            && sortie --dry-run --log-level debug --port 0 "$(workflow_for "$stage")" )
    done
}

# Both orchestrators are started here and killed by the trap, so neither can outlive the
# script and quietly keep dispatching agents.
#
# Each is launched through `env` with its output going to a process substitution rather than
# a pipeline. That matters: `env` execs into sortie, so $! is sortie's own pid. In a
# pipeline $! would be awk's, and in a subshell it would be the subshell's — killing either
# of those leaves the orchestrator running.
run_all() {
    local pids=() stage ws
    trap 'trap - INT TERM EXIT; kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; exit 0' INT TERM EXIT

    for stage in "${STAGES[@]}"; do
        ws=$(stage_ws "$stage")
        mkdir -p "$ws" || die "could not create $ws"
        env SORTIE_WORKSPACE_ROOT="$ws" SORTIE_DB_PATH="$(stage_db "$stage")" \
            sortie --port "$(port_for "$stage")" --log-level "$LOG_LEVEL" "$(workflow_for "$stage")" \
            > >(awk -v s="$stage" '{ printf "[%-6s] %s\n", s, $0; fflush() }') 2>&1 &
        pids+=("$!")
    done

    # With SORTIE_AUTO_UPDATE=on a fifth process watches upstream and restarts the stages
    # when it moved. Its pid joins the array so the trap above kills it too.
    if [[ $AUTO_UPDATE == on ]]; then
        watch_upstream "${pids[@]}" &
        pids+=("$!")
    fi
    wait
}

# --------------------------------------------------------------------------- auto-update
#
# The stages load their workflow once at startup, so a merge to the code they run is not
# live until someone restarts them. This watcher pulls the default branch, fast-forwards
# when the tree is safe, and restarts the stages — but never on top of a live agent. It
# only runs with SORTIE_AUTO_UPDATE=on; the default keeps the tree untouched.

# watch_upstream <stage-pid...>
# $@ is the pids of the four sortie processes, killed on restart. This function's own pid
# is appended to run_all's pids array by its caller, so Ctrl-C kills it with the stages.
watch_upstream() {
    local stage_pids=("$@")
    local default reason
    while :; do
        sleep "$AUTO_UPDATE_INTERVAL"

        # Same derivation the build stage's after_run hook uses, so this agrees with it
        # about which branch is the default.
        default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
        [[ -n $default ]] || default=main
        git fetch --quiet origin "$default" || continue
        [[ $(git rev-parse HEAD) == "$(git rev-parse "origin/$default")" ]] && continue

        # An issue mid-run must not be killed mid-turn, and a deferred update is re-checked
        # next interval, so this is checked before anything is merged — afterwards HEAD
        # would already match and the pending restart would never be noticed. One search
        # call, because `gh issue list --label` ANDs its labels.
        # Unknown count defers: a failed call means the safe assumption is that a stage is
        # mid-run, since restarting on top of one is the failure mode this guard exists for.
        local busy
        busy=$(gh api -X GET search/issues \
            -f q="repo:$REPO is:issue label:agent-planning,agent-building,agent-reviewing,agent-designing" \
            --jq .total_count 2>/dev/null)
        if [[ -z $busy || $busy -gt 0 ]]; then
            printf 'sortie: update pending — %s issue(s) mid-run, will re-check\n' "${busy:-unknown}"
            continue
        fi

        # Fast-forward only, and only when the tree is safe to move. -uno is load-bearing:
        # in this repo the installed config/sortie/* and scripts/sortie.sh are untracked
        # copies, so a plain --porcelain check would report dirty forever.
        reason=""
        [[ $(git symbolic-ref --short HEAD 2>/dev/null || echo detached) == "$default" ]] \
            || reason="HEAD is on $(git symbolic-ref --short HEAD 2>/dev/null || echo detached), not $default"
        [[ -n $reason || -z $(git status --porcelain -uno) ]] || reason="the working tree has uncommitted tracked changes"
        if [[ -n $reason ]]; then
            printf 'sortie: update available but %s — leaving the tree alone\n' "$reason"
            continue
        fi

        git merge --ff-only origin/"$default" 2>/dev/null \
            || { printf 'sortie: fast-forward to %s failed\n' "$default"; continue; }
        printf 'sortie: pulled %s — restarting the stages\n' "$(git rev-parse --short HEAD)"

        # Kill the stages first so the install and the exec below are adjacent. install.sh
        # --force overwrites scripts/sortie.sh, which is what is running; bash reads a
        # script by file offset, so nothing may be read from it between the rewrite and
        # the exec. The exec line is already parsed (it is part of this loop body), so
        # leaving only the exec after the install keeps the window to zero.
        kill "${stage_pids[@]}" 2>/dev/null

        # sortie-template installed into itself: the files the stages read are install.sh's
        # copies, so a merge to template/ changes nothing on disk until --force re-installs.
        # Ordinary target repos have no template/ and skip this.
        if [[ -d template && -f install.sh ]]; then
            ./install.sh . --force
        fi

        exec "$0" run
    done
}

run() {
    local want=${1:-}
    preflight
    ensure_labels

    if [[ -n $want ]]; then
        [[ " ${STAGES[*]} " == *" $want "* ]] || die "stage must be one of: ${STAGES[*]}"
        require_free_port "$want" "$(port_for "$want")"
        printf 'Watching %s for %s. Ctrl-C to stop.\n\n' "$REPO" "$(trigger_for "$want")"
        stage_env "$want"
        sortie --port "$(port_for "$want")" --log-level "$LOG_LEVEL" "$(workflow_for "$want")"
        return
    fi

    for stage in "${STAGES[@]}"; do require_free_port "$stage" "$(port_for "$stage")"; done

    printf 'Watching %s. Ctrl-C to stop all four stages.\n' "$REPO"
    printf '  design  system-design      → design        http://127.0.0.1:%s/\n' "$DESIGN_PORT"
    printf '  plan    agent-plan         → plan          http://127.0.0.1:%s/\n' "$PLAN_PORT"
    printf '  build   plan-approved      → build         http://127.0.0.1:%s/\n' "$BUILD_PORT"
    printf '  review  needs-code-review  → review        http://127.0.0.1:%s/\n\n' "$REVIEW_PORT"
    run_all
}

case "${1:-}" in
    setup)  setup ;;
    check)  check ;;
    run)    run "${2:-}" ;;
    stats)
        preflight
        stage=${2:-plan}
        [[ " ${STAGES[*]} " == *" $stage "* ]] || die "stage must be one of: ${STAGES[*]}"
        stage_env "$stage"
        sortie stats "$(workflow_for "$stage")"
        ;;
    -h|--help|help|'')
        sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)      die "unknown command '$1' — try --help" ;;
esac
