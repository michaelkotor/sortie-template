# AGENTS.md

Context for any coding agent working on this repository. Read this before changing anything.

## What this is

sortie-template is the installer and the prompt templates themselves, not something that
depends on them. `install.sh` copies `template/*` into a target repository; nothing here is
substituted at copy time. See [README.md](README.md) for what the installed pipeline does.

## Hard constraints

- **Nothing under `template/` is substituted at install time.** The workflows read
  `$SORTIE_REPO`, derived from the target's own git remote, and the prompts let `gh` resolve
  it from the clone. A change that bakes in a path, a repo name, or anything specific to
  *this* checkout breaks every project that installs it.
- **`install.sh` stays idempotent and non-destructive.** It never overwrites `AGENTS.md`,
  `config/sortie/.env`, or `config/sortie/AUTONOMY.md` in a target repo, `--force` included.
  If you touch `place()` or the AGENTS.md/AUTONOMY.md branches, keep that guarantee.
- **No credentials, ever.** `config/sortie/env.example` ships with empty values and stays
  that way — it's the one file a real token could end up in by accident. `.env` is gitignored
  by the installer itself (see the bottom of `install.sh`); don't add anything that writes a
  real token to disk here.
- **The pipeline is described in exactly one place**, `config/sortie/README.md`. Nothing else
  — not `AGENTS.md.example`, not `install.sh`'s comments — re-explains how the three stages
  work; they point at it instead. A description duplicated in two files is one of them lying
  eventually.
- **Bash only**, no new runtime dependency beyond `sortie`, `gh`, and `opencode`, which the
  scripts already assume are on `PATH`.

## Layout

| Path | What it holds |
| --- | --- |
| `install.sh` | Copies `template/*` into a target repo. Read this first — it's the whole install logic. |
| `template/AGENTS.md.example` | Skeleton `AGENTS.md` offered to a target repo that has none. |
| `template/config/sortie/WORKFLOW.*.md` | The three Sortie workflow definitions (plan, build, review). |
| `template/config/sortie/prompts/*.md` | What each stage is told. |
| `template/config/sortie/README.md` | The one place the pipeline itself is documented — for whoever reads an installed repo. |
| `template/config/sortie/AUTONOMY.md.example` | Skeleton for the autonomy decisions a target repo has to make once. |
| `template/config/sortie/env.example` | Token and switches a target repo copies to `.env`. Must never carry a real value. |
| `template/scripts/sortie.sh` | Setup / check / run / stats — installed into a target repo's `scripts/`. |

## Verifying a change

```bash
bash -n install.sh
bash -n template/scripts/sortie.sh
shellcheck install.sh template/scripts/sortie.sh
```

For anything touching `install.sh`'s copy logic, run it against a scratch git repo and check
the output by eye — twice, so the second run exercises the "already exists" / `--force` paths:

```bash
mkdir -p /tmp/sortie-install-test && git -C /tmp/sortie-install-test init -q
./install.sh /tmp/sortie-install-test
./install.sh /tmp/sortie-install-test        # should skip everything
./install.sh /tmp/sortie-install-test --force # should overwrite, except AGENTS.md/AUTONOMY.md
```

## Conventions

- Match the existing prose voice in comments and docs: terse, no filler, explains *why* not
  *what*. Comments in the scripts earn their place by recording something surprising, not by
  restating the line below them.
- Keep changes minimal and scoped — this is a small repo on purpose.
