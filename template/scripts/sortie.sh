#!/bin/bash
# sortie - turn GitHub issues into plans, and approved plans into pull requests.
#
#   ./scripts/sortie.sh setup                 create the labels, check credentials
#   ./scripts/sortie.sh check                 validate and poll once, changing nothing
#   ./scripts/sortie.sh run                   run all three stages (Ctrl-C stops them)
#   ./scripts/sortie.sh run plan|build|review run one stage on its own
#   ./scripts/sortie.sh stats [stage]         summarise past runs
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
# The stages are three Sortie processes because they run different models — planning and
# review on Opus, building on Sonnet — and Sortie has no per-dispatch-rule model setting.
# They keep separate databases, workspaces, and ports, and their label queries are
# disjoint, so none can pick up another's issues.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 3

ENV_FILE=config/sortie/.env
STAGES=(plan build review)
# Sortie's own log verbosity: debug, info, warn, error. `warn` leaves you the things that
# need you — failures, retries, escalations — and drops the once-a-minute poll chatter from
# three processes. It does not touch what the agents themselves print.
LOG_LEVEL=${SORTIE_LOG_LEVEL:-info}
PLAN_PORT=${SORTIE_PLAN_PORT:-7678}
BUILD_PORT=${SORTIE_BUILD_PORT:-7679}
REVIEW_PORT=${SORTIE_REVIEW_PORT:-7680}

workflow_for() { printf 'config/sortie/WORKFLOW.%s.md' "$1"; }
port_for()     { case $1 in plan) printf '%s' "$PLAN_PORT" ;; build) printf '%s' "$BUILD_PORT" ;; review) printf '%s' "$REVIEW_PORT" ;; esac; }
trigger_for()  { case $1 in plan) printf 'agent-plan' ;; build) printf 'plan-approved' ;; review) printf 'needs-code-review' ;; esac; }

die() { printf 'sortie: %s\n' "$1" >&2; exit 1; }

# --------------------------------------------------------------------------- environment
#
# Sortie's hooks only inherit SORTIE_*-prefixed variables, and the Claude Code subprocess
# inherits whatever this process holds. So everything is exported here rather than handed
# to `sortie --env-file`, which feeds config overrides only and not the agent's shell.

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
    require claude 'https://claude.com/claude-code'
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

    [[ -f AGENTS.md ]] || printf '\nNote: no AGENTS.md in the repository root. All three prompts read it for\n  project constraints and verification commands. Write one before relying on this.\n'

    cat <<EOF

Ready. Start all three stages with 'run' and leave them going; then, on any issue:

  label 'agent-plan'      → Opus comments a plan. It hands back as 'agent-review' for you
                            to approve, unless it judges the ticket small and unambiguous
                            enough to self-approve — then it goes straight on
  label 'plan-approved'   → Sonnet implements it and opens a PR. A trivial diff comes
                            straight back to you as 'agent-review'; anything else goes to
                            the reviewer (Opus), which approves it — back to you — or
                            sends it round again, at most twice

  label 'needs-human'     → that issue gets neither shortcut: you approve the plan, and
                            the PR is always reviewed

While a stage has an issue, the issue says so: the trigger label is replaced by
'agent-planning', 'agent-building', or 'agent-reviewing' for as long as that agent runs.

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
    wait
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

    printf 'Watching %s. Ctrl-C to stop all three stages.\n' "$REPO"
    printf '  plan    agent-plan         → Opus     http://127.0.0.1:%s/\n' "$PLAN_PORT"
    printf '  build   plan-approved      → Sonnet   http://127.0.0.1:%s/\n' "$BUILD_PORT"
    printf '  review  needs-code-review  → Opus     http://127.0.0.1:%s/\n\n' "$REVIEW_PORT"
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
        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)      die "unknown command '$1' — try --help" ;;
esac
