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

## Tidy

`tidy` is the other half: it deletes local branches whose work the trunk
already holds — the ones left behind after a PR is merged and the forge deletes
its own copy.

Git has **no configuration that does this**, and the settings people reach
for are not it:

| Setting | What it actually prunes |
| --- | --- |
| `fetch.prune` (see [`prune`](#prune) below) | stale `origin/*` **remote-tracking refs** on fetch |
| A forge's *delete branch on merge* | the branch **on the forge** |
| — | nothing deletes merged **local** branches; that needs a command |

So `tidy` prints every branch it would delete, with the repo and the short sha,
and then asks:

```console
$ astromech.sh tidy
branches already contained in their trunk — these would be deleted:

  ~/code/astromech  (merged into origin/main)
      ci/github-actions                            4055a00
      fix/lock-handling                            afdef48

  ~/code/nordrassil  (merged into origin/main)
      test/port-harnesses                          83b9d1f

  3 branch(es) in 2 repo(s).

Delete 3 merged branch(es)? [y/N]
```

Two things make it safe rather than merely careful:

- **"Merged" means contained in `origin/<trunk>`, not the local one.** A local
  trunk can be behind, or carry a merge commit that was never pushed. Measuring
  against it would call a branch merged on the strength of work nobody else
  has.
- **Deletion is `git branch -d`, never `-D`.** The list is astromech's opinion;
  `-d` is git's own, and a branch has to satisfy both. Where git refuses one the
  plan contained, the run says so, prints the `-D` command, exits non-zero and
  leaves the branch alone — forcing it is the operator's decision, not a
  script's.

Branches that are the trunk, checked out, or held by another worktree never
appear in the list. Repos mid-rebase, on a detached HEAD, or with no trunk are
reported and left alone.

```bash
astromech.sh tidy --dry-run        # list and stop; never asks
astromech.sh tidy                  # list, ask, delete
astromech.sh tidy --yes            # delete without asking
astromech.sh tidy --repo ~/code/api
astromech.sh maintain --tidy       # pull every repo first, then tidy it
```

`tidy` never touches the network, so it measures against whatever `origin/`
was last fetched — which can only make it see *fewer* branches as merged, never
more. `maintain --tidy` pulls each repo first and so sees all of them; it asks
once, before the first repo, because which branches become deletable is only
known after each pull (`tidy --dry-run` is where the list lives).

An unattended run must pass `--yes` explicitly. With no terminal to ask on and
no `--yes`, tidy refuses and exits non-zero rather than assume consent — and
rather than exit 0 as if there had been nothing to delete.

## Prune

The setting next door, and the one people mean when they ask whether git can
do tidy's job. It can't — but it can do the *other* half, and `prune` is where
that distinction is spelled out instead of assumed:

```console
$ astromech.sh prune
fetch.prune=unset
[info]  fetch.prune is unset, and git's own default is off — nothing is pruned.
          prunes:    stale origin/* remote-tracking refs, at every fetch. And
                     maintain's 'git pull --rebase' is a fetch, so maintenance
                     does it for you.
          does not:  local branches. No git setting deletes those — that is
                     'astromech.sh tidy'. Nor tags: that is
                     fetch.pruneTags, which this toggle leaves alone.
          why:       with a forge deleting each head branch as its PR lands,
                     every merged branch leaves an origin/* ref behind, and
                     'git branch -a', tab completion and your tooling go on
                     offering branches that are gone.
[info]  Turn it on with: astromech.sh prune on
```

```bash
astromech.sh prune            # the state, the explanation, and any overrides
astromech.sh prune on         # git config --global fetch.prune true
astromech.sh prune off        # …false
astromech.sh prune on --dry-run
```

Toggling prints the transition and the exact way back —
`fetch.prune: unset -> true (global)` followed by
`Undo with: git config --global --unset fetch.prune`, or the previous value
where there was one. The value reported on stdout is **read back** from the
config afterwards, not echoed from the intent, so a dry run reports what is
still there.

It also scans the discovered repos for the two settings that quietly beat a
global one — a repo-local `fetch.prune`, and `remote.origin.prune`, which
overrides `fetch.prune` at any scope:

```
override=/home/me/code/legacy	remote.origin.prune	false
[warn]  1 local override(s) above; a repo-local value and remote.origin.prune
        both beat the global setting.
```

Otherwise that's a thing you find out by wondering why one repo never prunes.

`fetch.pruneTags` is deliberately **not** offered: it prunes local tags the
remote no longer has, which is a much bigger promise than dropping a stale
branch ref, and nothing here needs it.

## Front-end

The interactive experience (first-run setup, multi-select ignore picker, menu)
lives in the [scomp-link](https://github.com/malahmen/scomp-link) front-end.
Apart from tidy's confirmation, this engine has no prompts, so it also runs
from cron or a systemd timer.

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
astromech.sh tidy --dry-run                  # merged local branches, listed
astromech.sh tidy                            # …then ask, then delete them
astromech.sh --help
```

| Command | Does |
| --- | --- |
| `maintain` | run maintenance on every discovered repo (`--repo`, `--dry-run`, `--tidy`) |
| `tidy` | list local branches already merged into the trunk, then delete them (`--repo`, `--dry-run`, `--yes`) |
| `prune [on\|off]` | show or toggle git's `fetch.prune`, with what it does and does not prune, and any repo overriding it (`--dry-run`) |
| `status` | per root: repos (relative path, branch, `*` if dirty) and ignored folders |
| `roots` / `add-root PATH…` / `remove-root PATH…` | manage roots (`add-root` prints each newly added absolute path; removing one also drops its ignores) |
| `children ROOT` | ROOT's top-level folders as TSV `name<TAB>ignored(0\|1)` |
| `ignores` / `set-ignores ROOT [NAME…]` | list / replace a root's ignored top-level folders |
| `repos` | discovered repos as TSV `root<TAB>repo` |
| `config` | resolved config as `key=value` (path, onboarded, counts) |
| `mark-onboarded` | record that the front-end's first-run prompt was answered |

Exit status: `maintain` exits 0 when no repo failed and 1 otherwise. Skipped
repos don't count as failures, so a repo that only has `develop` doesn't make
every cron run fail. `tidy` exits 0 when every planned deletion happened or you
declined, and 1 when git refused one or there was no way to ask. Logs go to
stderr. `status`, `roots`, `repos`, `children`, `ignores`, `config`, `add-root`
and tidy's plan print their data to stdout.

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

`test-prune.sh` writes to a global git config, so it first proves git honours
`$GIT_CONFIG_GLOBAL` (2.32+) and skips itself if not — the real `~/.gitconfig`
is not an acceptable place to find that out.

`test-tidy.sh` needs `setsid` to observe the confirmation gate refusing with no
controlling terminal, and python's `pty` to answer the question with one. It
skips those checks, rather than failing, where either is missing.
