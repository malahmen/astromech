# astromech

> "Beep boop." — routine maintenance, every repo, one command.

A gum-free, flag-driven bash CLI that keeps every git repository under a set of
folders on a fresh default branch. Give it one or more **roots** (folders that
hold repos) and the top-level folders under them to **ignore**; `maintain` then
walks every repo below the roots and, per repo:

| Repo state | What happens |
| --- | --- |
| On a feature branch | `git add -A` + commit (`wip: auto-commit before astromech maintenance (YYYY-MM-DD)`), then `git checkout main` (or `master`) |
| On main/master with local changes | `git stash push -u` — the stash is **left for you** (never popped) |
| Then, always | `git pull --rebase` |

**Nothing is pushed.** If a step fails, astromech reports it, leaves the repo
the way that step left it, and goes on to the next repo. A rebase that hits a
conflict stays stopped, so whoever ran maintenance can resolve it
(`git status`, then `git rebase --continue` or `--abort`).

These repos are **skipped and reported**, never touched:

- a rebase, merge, cherry-pick, revert or bisect is in progress
- detached HEAD
- neither `main` nor `master` exists, locally or on `origin`

The interactive experience (first-run setup, multi-select ignore picker, menu)
lives in the [scomp-link](https://github.com/malahmen/scomp-link) front-end;
this engine has no prompts, so it also runs from cron or a systemd timer.

## Requirements

bash ≥ 4 (on macOS: `brew install bash`) and git ≥ 2.13. Nothing else.

## Usage

```bash
astromech.sh add-root ~/code ~/work          # folders holding git repos
astromech.sh children ~/code                 # top-level folders (name<TAB>ignored)
astromech.sh set-ignores ~/code archive tmp  # replace ~/code's ignored folders
astromech.sh set-ignores ~/code              # …or clear them
astromech.sh status                          # tree: repos [branch *dirty] + ignored
astromech.sh maintain --dry-run              # what would happen
astromech.sh maintain                        # do it
astromech.sh maintain --repo ~/code/api      # just one repo
astromech.sh --help
```

| Command | Does |
| --- | --- |
| `maintain` | run maintenance on every discovered repo (`--repo`, `--dry-run`) |
| `status` | per root: repos (relative path, branch, `*` if dirty) and ignored folders |
| `roots` / `add-root PATH…` / `remove-root PATH…` | manage roots (`add-root` prints each newly added absolute path; removing one also drops its ignores) |
| `children ROOT` | ROOT's top-level folders as TSV `name<TAB>ignored(0\|1)` |
| `ignores` / `set-ignores ROOT [NAME…]` | list / replace a root's ignored top-level folders |
| `repos` | discovered repos as TSV `root<TAB>repo` |
| `config` | resolved config as `key=value` (path, onboarded, counts) |
| `mark-onboarded` | record that the front-end's first-run prompt was answered |

Exit status: `maintain` exits 0 when no repo failed and 1 otherwise. Skipped
repos don't count as failures, so a repo that only has `develop` doesn't make
every cron run fail. Logs go to stderr. `status`, `roots`, `repos`, `children`,
`ignores`, `config` and `add-root` print their data to stdout.

## Discovery

Repos are found **recursively** below each root. Any folder containing `.git`
counts, whether `.git` is a directory or a file (worktrees and submodules). The
walk never goes inside a repo it has found, and it skips hidden folders,
symlinks and ignored folders. It stops at `ASTROMECH_MAX_DEPTH` levels below the
root (default 6). Ignores apply to a root's **top-level** folders, and an
ignored folder's whole subtree is skipped.

## Config

`~/.config/astromech/astromech.conf` (override: `--config PATH` or
`$ASTROMECH_CONFIG`). Plain `key=value` lines, written atomically:

```
onboarded=1
root=/Users/me/code
root=/Users/me/work
ignore=/Users/me/code/archive
```

## Cron

```cron
0 8 * * 1-5  /opt/homebrew/bin/bash ~/src/astromech/astromech.sh maintain >> ~/.local/state/astromech.log 2>&1
```

Without a terminal, log lines get a UTC timestamp and `GIT_TERMINAL_PROMPT=0` is
set, so an HTTPS remote that needs credentials fails instead of hanging the run.

## Tests

```bash
tests/run-all.sh      # file:// bare remotes, no network
```
