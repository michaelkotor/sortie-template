#!/bin/bash
# install.sh - copy the Sortie four-stage setup into a project.
#
#   ./install.sh [target-repo] [--force] [--run]
#
# Defaults to the current directory. Existing files are left alone unless --force is given,
# so re-running this to pick up template changes is safe: it reports what it skipped and
# you diff those yourself.
#
# --run installs, creates the labels, and starts all four stages in one go, which is the
# loop you want while iterating on the template. It implies --force: running means running
# what the template says now. Your credentials, AGENTS.md and config/sortie/AUTONOMY.md are
# never overwritten either way.
#
# Nothing needs committing for a run. The agents work in clones of the remote, but the
# workflow hooks carry AGENTS.md and config/sortie/AUTONOMY.md over from this working copy
# when the clone does not have them, and exclude them from git so they cannot reach a PR.
#
# Nothing is substituted. The workflows read the repository from $SORTIE_REPO, which
# scripts/sortie.sh derives from the git remote, and the prompts let `gh` resolve it from
# the clone. The one thing the template cannot supply is AGENTS.md, which is where a
# project says what an agent needs to know about it.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/template"
TARGET=""
FORCE=0
RUN=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --run)   RUN=1; FORCE=1 ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) printf 'install: unknown option %s\n' "$arg" >&2; exit 1 ;;
        *)  TARGET="$arg" ;;
    esac
done

TARGET="${TARGET:-$PWD}"
die() { printf 'install: %s\n' "$1" >&2; exit 1; }

[[ -d $SRC ]]    || die "template directory missing: $SRC"
[[ -d $TARGET ]] || die "no such directory: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"
[[ -d $TARGET/.git ]] || die "$TARGET is not a git repository"

copied=0 skipped=0

place() {  # place <relative-source> <relative-destination>
    local src="$SRC/$1" dst="$TARGET/$2"
    [[ -f $src ]] || die "template file missing: $1"
    if [[ -e $dst && $FORCE -eq 0 ]]; then
        printf '  skipped  %s (exists)\n' "$2"
        skipped=$((skipped + 1))
        return
    fi
    mkdir -p "$(dirname "$dst")" || die "could not create $(dirname "$dst")"
    cp "$src" "$dst" || die "could not write $2"
    printf '  %s  %s\n' "$([[ $FORCE -eq 1 && -e $dst ]] && echo 'written ' || echo 'copied  ')" "$2"
    copied=$((copied + 1))
}

printf 'Installing into %s\n\n' "$TARGET"

place config/sortie/WORKFLOW.plan.md   config/sortie/WORKFLOW.plan.md
place config/sortie/WORKFLOW.build.md  config/sortie/WORKFLOW.build.md
place config/sortie/WORKFLOW.review.md config/sortie/WORKFLOW.review.md
place config/sortie/WORKFLOW.design.md config/sortie/WORKFLOW.design.md
place config/sortie/prompts/plan.md    config/sortie/prompts/plan.md
place config/sortie/prompts/build.md   config/sortie/prompts/build.md
place config/sortie/prompts/review.md  config/sortie/prompts/review.md
place config/sortie/prompts/design.md  config/sortie/prompts/design.md
place config/sortie/env.example        config/sortie/env.example
place config/sortie/README.md          config/sortie/README.md
place scripts/sortie.sh                scripts/sortie.sh
chmod +x "$TARGET/scripts/sortie.sh" 2>/dev/null

# AUTONOMY.md is the project's own knowledge — what an agent may never decide alone here —
# so it is written once and never again, --force included. Everything the template owns
# lives in config/sortie/README.md next to it, which is refreshed freely.
if [[ -e $TARGET/config/sortie/AUTONOMY.md ]]; then
    printf '  present  config/sortie/AUTONOMY.md (left alone — yours)\n'
else
    place config/sortie/AUTONOMY.md.example config/sortie/AUTONOMY.md
    printf '           ^ list what a human must decide here before relying on the shortcuts\n'
fi

# AGENTS.md is the project's own knowledge, so the skeleton is only offered when the
# project has none, and an existing one is never rewritten.
#
# What it gets from an upgrade is one pointer at config/sortie/README.md, appended once if
# it is missing. Nothing about the workflow is described in AGENTS.md itself: a description
# there would have to be re-edited every time the pipeline changed, and a stale one is worse
# than none, since every stage reads this file as binding.
if [[ -e $TARGET/AGENTS.md ]]; then
    printf '  present  AGENTS.md (left alone)\n'
    if grep -q 'config/sortie/README\.md' "$TARGET/AGENTS.md"; then
        printf '  present  AGENTS.md already points at config/sortie/README.md\n'
    else
        cat >> "$TARGET/AGENTS.md" <<'POINTER'

## Automated issue workflow

Labelled issues are handled by OpenCode and Claude Code through Sortie. How that works,
which labels drive it, and what this project never lets an agent decide alone:
[`config/sortie/README.md`](config/sortie/README.md).
POINTER
        printf '  appended a pointer to config/sortie/README.md in AGENTS.md\n'
    fi
    # An older install described the pipeline in AGENTS.md itself. That description is now
    # somewhere else and out of date, but it is the project's prose, so say so rather than
    # editing around it.
    if grep -qE 'sortie-plan\.sh|in two stages|in three stages' "$TARGET/AGENTS.md"; then
        printf '  stale    AGENTS.md still describes the workflow itself — that moved to\n'
        printf '           config/sortie/README.md; delete the old paragraph by hand\n'
    fi
else
    place AGENTS.md.example AGENTS.md
    printf '           ^ a skeleton — fill it in before running the build stage\n'
fi

# Credentials are never touched: the template ships env.example, and .env is yours.
if [[ -f $TARGET/config/sortie/.env ]]; then
    printf '  present  config/sortie/.env (left alone — credentials untouched)\n'
fi

# Files an earlier version of this template installed, which nothing reads any more. Left
# on disk, because deleting a file in someone's repository is not this script's business.
for stale in scripts/sortie-plan.sh config/sortie/.env.example; do
    [[ -e $TARGET/$stale ]] && printf '  stale    %s — superseded, safe to delete\n' "$stale"
done

# The token lives in config/sortie/.env, which must never be committed.
if [[ -f $TARGET/.gitignore ]] && grep -qE '^\s*(config/sortie/)?\.env\s*$' "$TARGET/.gitignore"; then
    printf '  present  .gitignore already covers .env\n'
else
    printf 'config/sortie/.env\n' >> "$TARGET/.gitignore" \
        && printf '  appended config/sortie/.env to .gitignore\n'
fi

printf '\n%d copied, %d skipped.\n' "$copied" "$skipped"
[[ $skipped -gt 0 && $FORCE -eq 0 ]] && printf 'Re-run with --force to overwrite the skipped files.\n'

# --run: labels, then all four stages, in the target repository. exec, so Ctrl-C reaches
# the orchestrators directly and this script is not left sitting in the middle.
if [[ $RUN -eq 1 ]]; then
    [[ -x $TARGET/scripts/sortie.sh ]] || die "no scripts/sortie.sh in $TARGET to run"
    printf '\nSetting up %s ...\n\n' "$TARGET"
    cd "$TARGET" || die "could not enter $TARGET"
    ./scripts/sortie.sh setup || die "setup failed — fix that before running"
    printf '\nStarting all four stages. Ctrl-C stops them.\n\n'
    exec ./scripts/sortie.sh run
fi

printf '\nNext, in %s:\n\n' "$TARGET"

if [[ -f $TARGET/config/sortie/.env ]]; then
    cat <<EOF
  1. Your config/sortie/.env is already there and was not touched. Compare it against
     env.example if you want the new autonomy switches — they default to on.
EOF
else
    cat <<EOF
  1. cp config/sortie/env.example config/sortie/.env
     and paste in a fine-grained GitHub token — the file says which permissions.
EOF
fi

cat <<EOF
  2. Fill in AGENTS.md — all four prompts read it, and the build and review stages run
     the commands in its "Verifying a change" section — and then
     config/sortie/AUTONOMY.md, which is what the shortcuts check before taking themselves.
  3. ./scripts/sortie.sh setup     creates the eleven labels, checks the token
  4. ./scripts/sortie.sh run       watches for all four trigger labels

Or do 3 and 4 in one step next time: re-run this installer with --run, which reinstalls
the template, creates the labels, and starts all four stages.

Then label an issue 'agent-plan'. You get a plan as a comment; add 'plan-approved'
and you get a pull request, reviewed before it reaches you.

Small, unambiguous tickets take a shorter route: the planner may approve its own plan and
the builder may skip the review, saying so on the issue either way. Label an issue
'needs-human' to force the full route, or see the autonomy switches in env.example.
EOF
