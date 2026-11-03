# astromech

[![ci](https://github.com/malahmen/astromech/actions/workflows/ci.yml/badge.svg)](https://github.com/malahmen/astromech/actions/workflows/ci.yml)

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

Every run that finds the trunk dirty adds a stash, so under cron they pile up.
The summary lists each repo still holding astromech stashes, with the count,
and `status` shows it beside the branch (`[main, 2 stashed]`).

**Nothing is pushed.** If a step fails, astromech reports it, leaves the repo
the way that step left it, and goes on to the next repo. A rebase that hits a
conflict stays stopped, so whoever ran maintenance can resolve it
(`git status`, then `git rebase --continue` or `--abort`).

Up to four repos are maintained at once (`--jobs N`, see
[Parallel runs](#parallel-runs)); the report still reads one repo after
another, in order, one line each (see [Output](#output)).

These repos are **skipped and reported**, never touched:

- a rebase, merge, cherry-pick, revert or bisect is in progress
- detached HEAD
- neither `main` nor `master` exists, locally or on `origin`
- local changes on a long-lived branch that is not the trunk — `main`,
  `master`, `develop`, `development`, `trunk`, `stable`, `release/*`,
  `hotfix/*` (the names `tidy` never deletes). In a git-flow repo whose
  `origin/HEAD` is `develop`, a dirty `main` or `release/*` is not a feature
  branch: a wip commit there is published by the next push. The work stays in
  the working tree, on that branch, for you to commit or stash.

## Tidy

`tidy` is the other half: it deletes local branches whose work the trunk
already holds — the ones left behind after a PR is merged.

Note that `tidy` only ever touches **local** branches. Whether the branch on
the forge goes too is a per-repository setting there ("Automatically delete
head branches" on GitHub), it is **off by default**, and nothing in git or in
astromech turns it on. If it is off, merged branches pile up on the remote
while your local clone looks clean — and `git branch -r` goes on listing them,
because they really are still there. `fetch.prune` does not help: there is
nothing stale to prune.

Git has **no configuration that does this**, and the settings people reach
for are not it:

| Setting | What it actually prunes |
| --- | --- |
| `fetch.prune` (see [`prune`](#prune) below) | stale `origin/*` **remote-tracking refs** on fetch |
| A forge's *delete branch on merge* | the branch **on the forge** — off by default, and per repository |
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

Branches that are the trunk, checked out, or held by another worktree (being
rebased or bisected there included) never appear in the list - and neither do
the long-lived names `main`, `master`, `develop`, `development`, `trunk`,
`stable`, `release/*` and `hotfix/*`, whatever `origin/HEAD` names as the trunk
(in a git-flow repo a `main` behind `develop` is "merged", and is still not
tidied). Repos mid-rebase, on a detached HEAD, or with no trunk are reported and
left alone. A linked worktree (`git worktree add`) under a root is part of its
repository, not a second one.

`status` shows the same branches under each repo, so you can see what has piled
up without being asked to delete anything:

```console
$ astromech.sh status
~/code
├── akinn                                    [main]
├── clonecast                                [main]
│    - demo/one                               feb962b
│    - demo/two                               feb962b
├── nordrassil                               [main *]
└── younglings-key                           [main]
     - fix/nss-read-back                      069b6da

[branch *] = uncommitted changes
- branch   = already contained in the trunk on origin; astromech.sh tidy deletes these
3 branch(es) in 2 repo(s) can be tidied.
```

That listing comes from the function `tidy` plans with, not a second
similar-looking query. Two implementations of "already merged" would eventually
disagree, and a status that promises a deletion `tidy` then refuses — or hides
one it would make — is worse than no listing at all. The last two legend lines
appear only when there is something to list.

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

## Output

Each repo is one line: its path under the root (under `~` when the run spans
several roots), then `ok:` and what was done, `skipped:` and why, or `FAILED:`
and why. Unattended - cron, a pipe, a front-end reading it - a line is printed
when its repo and every repo before it are done, in repo order, behind the
log's timestamp, with no escape sequences:

```console
2026-11-03T08:00:04Z [info]  Maintaining 6 repo(s)…
2026-11-03T08:00:06Z a-feature   ok: committed 'feature', feature → main, pulled
2026-11-03T08:00:06Z b-stash     ok: stashed, pulled
2026-11-03T08:00:06Z c-detached  skipped: detached HEAD
2026-11-03T08:00:06Z d-hook      FAILED: commit on 'feature' failed (hook? identity?) — nothing changed
          hook says no
2026-11-03T08:00:07Z e-tidy      ok: pulled, 2 branches deleted, 1 refused
          error: The branch 'stale' is not fully merged.
          If you are sure you want to delete it, run 'git branch -D stale'.
2026-11-03T08:00:07Z f-behind    ok: pulled, 1 branch deleted
```

Under a line goes only what explains it: git's own output when the repo
failed or tidy was refused, or a warning. The steps themselves (committed,
checked out, stashed, deleted) come with `--verbose`, under each repo's line.
The summary that follows is unchanged, every skip and failure in it in full.

On a terminal (stderr is one and `TERM` is not `dumb`) the same lines are drawn
live: finished repos above, and below them a block of the ones still to come,
redrawn in place - `queued`, or what each is doing (`pulling… 12s`, with a
spinner) - until each turns into its final line. With `--jobs 1` the one repo
being worked on is a line rewritten as its steps go (no clock there: git may be
asking for a passphrase on it). Lines are cut to the terminal's width, never
wrapped, and a block taller than the terminal ends in `… N more`. Ctrl-C leaves
every repo's line saying what became of it (`stopped`, `not started`) and the
cursor visible.

## Parallel runs

A pull waits on the network, so one repo at a time made a run as long as the
sum of its pulls. `maintain` runs up to `--jobs N` repos at once — default 4,
or `jobs=` in the config; `--jobs 1` is one at a time, exactly as before. A
run then takes about as long as its slowest pulls. On 20 real clones pulling
from GitHub over ssh, 49-109 s one at a time became 16 s with four jobs and
11-13 s with eight.

- **The same report.** Each repo's whole job (maintain, then its tidy with
  `--tidy`) runs in the background with its output held back; a repo is
  printed as soon as it and every repo before it are done. The lines, the
  summary and the exit status are byte for byte those of `--jobs 1`, and one
  extra line says how many run at once. With stdout and stderr on different
  files each keeps its own stream.
- **One git dir, one job.** Two repos whose git dirs are the same, or one
  inside the other (a submodule's, under its superproject's `.git/modules`, is
  written by the superproject's pull too), never run at the same time.
- **Nothing prompts.** Nobody could answer, and a background job reading the
  terminal would stop the run for good. So `GIT_TERMINAL_PROMPT=0`, and ssh
  runs with `-o BatchMode=yes`, appended to your `GIT_SSH_COMMAND` or to the
  repo's `core.sshCommand` when there is one. Credentials must come from
  `ssh-agent` or a credential helper, as under cron; a repo that would ask
  fails, saying why, and the rest carry on. `GIT_SSH` (a program, not a command
  line) cannot be given options, so it is left alone with a warning. A key that
  needs its passphrase typed means `--jobs 1`, or `ssh-add` first.
- **A crash is one repo's failure.** A job that dies without its result — a
  shell error, a signal — is reported `FAILED` for its repo; the others are
  maintained and counted as usual.
- **Ctrl-C** (or TERM, HUP) stops every job and every git under it, prints
  each started repo's line (`stopped` for the ones stopped mid-job, which the
  closing warning names), releases the run lock and exits 130 (143, 129).

A single repo (`--repo`, or only one discovered) always runs the old way.

`status` reads its repos with the same runner and `--jobs` (no lock and no
network there, so none of the rules above apply), and prints the same tree.
Each repo now costs three git calls in the common case - one `rev-parse` at
discovery for its git dir, common dir and work tree, then one `status
--porcelain=v2 --branch` and one `for-each-ref` for its branch, dirt, trunk,
stash and branches - where it took fifteen; `maintain` and `tidy` read through
the same functions. On 18 repos, `status` went from 9.5 s to 2.5 s one at a
time and 1.6-2 s with four jobs.

## Front-end

The interactive experience (first-run setup, multi-select ignore picker, menu)
lives in the [scomp-link](https://github.com/malahmen/scomp-link) front-end.
Apart from tidy's confirmation, this engine has no prompts, so it also runs
from cron or a systemd timer.

## Requirements

bash ≥ 4 (on macOS: `brew install bash`) and git ≥ 2.23 (for `tidy`'s view of
which branches are checked out; checked at start). Nothing else.

## Usage

```bash
astromech.sh add-root ~/code ~/work          # folders holding git repos
astromech.sh children ~/code                 # top-level folders (name<TAB>ignored)
astromech.sh set-ignores ~/code archive tmp  # replace ~/code's ignored folders
astromech.sh set-ignores ~/code              # …or clear them
astromech.sh set-ignores -- ~/code -scratch  # a name starting with - goes after --
astromech.sh status                          # tree: repos [branch *dirty, N stashed] + ignored
astromech.sh maintain --dry-run              # what would happen
astromech.sh maintain                        # do it
astromech.sh maintain --repo ~/code/api      # just one repo
astromech.sh maintain --jobs 8               # eight repos at a time (default 4; 1 = one by one)
astromech.sh tidy --dry-run                  # merged local branches, listed
astromech.sh tidy                            # …then ask, then delete them
astromech.sh --help
```

| Command | Does |
| --- | --- |
| `maintain` | run maintenance on every discovered repo (`--repo`, `--dry-run`, `--tidy`, `--jobs N`) |
| `tidy` | list local branches already merged into the trunk, then delete them (`--repo`, `--dry-run`, `--yes`) |
| `prune [on\|off]` | show or toggle git's `fetch.prune`, with what it does and does not prune, and any repo overriding it (`--dry-run`) |
| `status` | per root: repos (relative path, branch, `*` if dirty), the branches `tidy` would delete, and ignored folders |
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

Repos are found **recursively** below each root. A folder containing `.git`
counts, whether `.git` is a directory or a file (a submodule) — with one
exception: a linked worktree (`git worktree add`), whose `.git` is also a file,
is part of its repository and never counted as a repository of its own. When
that repository is itself under no root (or is ignored), the worktree is not
maintained, and every run names it in a warning rather than dropping it without
a word; add the repository's folder as a root to cover it. The
walk never goes inside a repo it has found, and it skips hidden folders,
symlinks and ignored folders. It stops at `ASTROMECH_MAX_DEPTH` levels below the
root (default 6). Ignores apply to a root's **top-level** folders, and an
ignored folder's whole subtree is skipped.

## Config

`~/.config/astromech/astromech.conf` (override: `--config PATH` or
`$ASTROMECH_CONFIG`). Plain `key=value` lines, written atomically:

```
onboarded=1
jobs=4
root=/Users/me/code
root=/Users/me/work
ignore=/Users/me/code/archive
```

`jobs=` (1-64, optional) is the default for `--jobs` (`maintain`, `status`); the flag wins.
astromech never writes it, only keeps it; a value that is not a number in range
is named in a warning and the default of 4 used.

## Cron

```cron
0 8 * * 1-5  /opt/homebrew/bin/bash ~/src/astromech/astromech.sh maintain >> ~/.local/state/astromech.log 2>&1
```

Without a terminal, log lines get a UTC timestamp and `GIT_TERMINAL_PROMPT=0` is
set, so an HTTPS remote that needs credentials fails instead of hanging the run.
With more than one job (the default) that holds with a terminal too, and ssh
gets `BatchMode=yes` (see [Parallel runs](#parallel-runs)).

`maintain` and `tidy` take one run lock per user,
`~/.local/state/astromech/run.lock`, so a cron run and one started by hand
never interleave. The path depends on `$HOME` alone — not on
`XDG_RUNTIME_DIR` or `XDG_STATE_HOME`, which a desktop session sets and cron
does not. A lock whose holder is gone (killed, or from before a reboot) is
reported and taken over.

## Tests

```bash
tests/run-all.sh      # file:// bare remotes, no network
```

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs `shellcheck -S
warning` over `astromech.sh` and `tests/*.sh`, then the whole suite, on every
push to `main`, every pull request, and on demand. No secrets, no services:
the suites work in temporary directories against `file://` remotes.

The shellcheck step globs `tests/*.sh` deliberately. A named file list quietly
stops covering the next test file somebody adds, which is the kind of gap you
only find by not finding anything.

The versions step prints `bash`, `git`, `shellcheck`, `setsid` and whether
python's `pty` imports — because a suite that behaves differently on the runner
than on a workstation is the hardest kind to debug from a log, and two of those
are what the skip conditions below depend on.

### Suites

| File | Checks | What it covers |
| --- | ---: | --- |
| `test-tidy.sh` | 69 | the plan, the gate, `git branch -d` never `-D`, and that `status` lists exactly what `tidy` would delete |
| `test-prune.sh` | 47 | the `fetch.prune` toggle, its read-back, and the overrides that beat it |
| `test-local.sh` | 51 | maintenance per repo state: commit, stash, pull, what is skipped, stash counts, and nested roots' ignores |
| `test-failures.sh` | 18 | a hook refusing the wip commit, main and master together, a file named like the trunk, tidy meeting a run in progress |
| `test-trunks-worktrees.sh` | 47 | long-lived branches: never tidied, never wip-committed by `maintain`; linked worktrees (one stray outside every root is named); a branch rebased or bisected elsewhere; deepest-root attribution; `status` taking no optional locks |
| `test-locked.sh` | 17 | the run lock: a stale one whose holder is gone, one path whatever the environment, never visible without its pid |
| `test-default-branch.sh` | 10 | which branch is the trunk, in the orders that matter |
| `test-jobs.sh` | 73 | `--jobs`: the same report as one at a time, totals that add up, nested git dirs never at once, prompts that fail instead of hanging, a crashed job, Ctrl-C/TERM releasing the lock; one line per repo off a terminal, exactly (golden), in order, `--verbose` restoring the steps |
| `test-live.sh` | 35 | the live block under a real terminal, read back through a small terminal emulator: lines updated in place and left in their final state, `--jobs 1`'s rewritten line, a narrow and short terminal (cut, never wrapped; `… N more`), TERM interrupting it (readable block, cursor back), `TERM=dumb` |
| `test-reads.sh` | 17 | fewer git calls, same answers: `status` and `tidy --dry-run` byte for byte the previous engine's over a tree of awkward states (detached, mid-rebase, a stale `origin/HEAD`, a tag named like the branch, an unborn branch, no origin), with `--jobs 1` and `4`; calls counted through a `git` wrapper |

**384 checks** in total.

`test-prune.sh` writes to a global git config, so it first proves git honours
`$GIT_CONFIG_GLOBAL` (2.32+) and skips itself if not — the real `~/.gitconfig`
is not an acceptable place to find that out.

`test-jobs.sh` answers nothing over the network either: a stub `git` delays
or hangs a pull and logs when it starts and ends, a stub `ssh` and a remote
helper stand in for a prompt nobody answers, and a stub `date` makes one job
crash. Its credential check needs python's `pty` (a terminal on stdin is the
only case in which one-at-a-time maintenance would prompt) and its Ctrl-C
check needs `perl`; each is skipped, not failed, without them.

`test-live.sh` needs python's `pty` too, and skips itself without it.

`test-tidy.sh` needs `setsid` to observe the confirmation gate refusing with no
controlling terminal, and python's `pty` to answer the question with one. It
skips those checks, rather than failing, where either is missing.

## License

[MIT](LICENSE) © 2026 malahmen.
