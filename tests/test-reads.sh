#!/usr/bin/env bash
# Fewer git calls, same answers (Kamino item 239): status, tidy's plan and
# maintain read each repository with one rev-parse (discovery), one
# for-each-ref and - where the dirty state is needed - one status, and status
# builds its rows with the job runner. What they print must not change by a
# byte, with --jobs 1 or 4, so the expected output below is the previous
# engine's (main at a814128, run on this very fixture), kept literally; the
# call counts are what changed.
#
# No network: file:// remotes only.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"; unset XDG_RUNTIME_DIR

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
same()  { if [[ "$1" == "$2" ]]; then return 0; fi; diff <(printf '%s\n' "$2") <(printf '%s\n' "$1") | sed 's/^/        /'; return 1; }

R="$T/code"; mkdir -p "$R"
# mk <name> [trunk] — a bare origin, cloned, one commit, origin/HEAD set.
mk() {
    local n="$1" tr="${2:-main}" c="$R/$1"
    git init -q --bare -b "$tr" "$T/remotes/$n.git"
    git clone -q "$T/remotes/$n.git" "$c" 2>/dev/null
    git -C "$c" symbolic-ref HEAD "refs/heads/$tr"
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" push -q -u origin "$tr"; git -C "$c" remote set-head origin "$tr"
}
# merged <repo> <branch> [trunk] [local] — a branch merged into the trunk
# (main), which is pushed unless 'local'.
merged() {
    local tr="${3:-main}"
    git -C "$1" checkout -q -b "$2"; echo "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2"
    git -C "$1" checkout -q "$tr"; git -C "$1" merge -q --no-ff -m "merge $2" "$2"
    [[ "${4:-}" == local ]] || git -C "$1" push -q origin "$tr"
}

# The states every reader has to tell apart.
mk a-clean
mk b-dirty;    echo change >> "$R/b-dirty/f"; echo new > "$R/b-dirty/untracked"
mk c-stash;    echo s >> "$R/c-stash/f"; git -C "$R/c-stash" stash push -q -m "astromech: before pull (2026-01-01)"
mk d-detached; git -C "$R/d-detached" checkout -q --detach
mk e-rebase;   merged "$R/e-rebase" done-e; git -C "$R/e-rebase" checkout -q --detach
mkdir -p "$R/e-rebase/.git/rebase-merge"
mk f-feature;  merged "$R/f-feature" done-f; merged "$R/f-feature" done-g
git -C "$R/f-feature" checkout -q -b work; echo w > "$R/f-feature/w"
# a tag and a branch named alike: the current branch prints as heads/<name>
mk g-tagged;   merged "$R/g-tagged" v1; git -C "$R/g-tagged" tag v1 v1; git -C "$R/g-tagged" tag main main
# git-flow: origin/HEAD -> develop; main is long-lived, never planned
mk h-flow develop; git -C "$R/h-flow" branch main; merged "$R/h-flow" feat-h develop
# origin/HEAD left pointing at a branch origin no longer has, while a local
# branch of that name exists: that branch is the trunk, measured locally
mk i-stale;    git -C "$R/i-stale" branch trunk2
merged "$R/i-stale" done-i trunk2 local; git -C "$R/i-stale" checkout -q main
git -C "$R/i-stale" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk2
# no origin at all
mkdir -p "$R/j-local"; git init -q -b main "$R/j-local"; echo x > "$R/j-local/f"
git -C "$R/j-local" add f; git -C "$R/j-local" commit -qm x
git -C "$R/j-local" checkout -q -b shipped; echo s > "$R/j-local/s"; git -C "$R/j-local" add s; git -C "$R/j-local" commit -qm s
git -C "$R/j-local" checkout -q main; git -C "$R/j-local" merge -q --no-ff -m m shipped
# a branch with no commit yet
mkdir -p "$R/k-unborn"; git init -q -b trunk "$R/k-unborn"
# a merged branch checked out in a second worktree (outside the root)
mk l-wt;       merged "$R/l-wt" parked; merged "$R/l-wt" free-l; git -C "$R/l-wt" worktree add -q "$T/l-wt-extra" parked
printf 'onboarded=1\nroot=%s\n' "$R" > "$T/c.conf"
export ASTROMECH_CONFIG="$T/c.conf"
norm() { sed "s#${T}#T#g"; }

echo "## 1. status prints what it printed before, with any --jobs"
EXPECTED_STATUS='T/code
├── a-clean                                  [main]
├── b-dirty                                  [main *]
├── c-stash                                  [main, 1 stashed]
├── d-detached                               [(detached)]
├── e-rebase                                 [(rebase)]
├── f-feature                                [work *]
│    - done-f                                 aedd84e
│    - done-g                                 b201a8a
├── g-tagged                                 [heads/main]
│    - v1                                     e43a138
├── h-flow                                   [develop]
│    - feat-h                                 c5b0956
├── i-stale                                  [main]
│    - done-i                                 fa33ffb  (vs the local trunk2 — no origin)
├── j-local                                  [main]
│    - shipped                                f71c9b2  (vs the local main — no origin)
├── k-unborn                                 [trunk]
└── l-wt                                     [main]
     - free-l                                 2a7cbba

[branch *] = uncommitted changes
[branch, N stashed] = N changes astromech stashed and nobody has picked up (git stash list)
- branch   = already contained in the trunk on origin; astromech.sh tidy deletes these
             (where a repo has no origin, against its local trunk instead)
7 branch(es) in 6 repo(s) can be tidied.'
for j in 1 4; do
    out="$(bash "$AM" status --jobs "$j" 2>"$T/err" | norm)"; rc=$?
    check "status --jobs ${j}: the same tree, byte for byte" same "$out" "$EXPECTED_STATUS"
    check "  exit 0, nothing on stderr"                      bash -c "[ $rc -eq 0 ] && [ ! -s '$T/err' ]"
done
out="$(bash "$AM" status 2>/dev/null | norm)"
check "status (default jobs): the same"                  same "$out" "$EXPECTED_STATUS"
check "  and leaves no buffers behind"                   bash -c "[ -z \"\$(ls -A '$TMPDIR')\" ]"

echo "## 2. tidy plans what it planned before, with any --jobs"
EXPECTED_PLAN='branches already contained in their trunk — these would be deleted:

  T/code/f-feature  (merged into origin/main)
      done-f                                       aedd84e
      done-g                                       b201a8a

  T/code/g-tagged  (merged into origin/main)
      v1                                           e43a138

  T/code/h-flow  (merged into origin/develop)
      feat-h                                       c5b0956

  T/code/i-stale  (merged into trunk2)
      done-i                                       fa33ffb

  T/code/j-local  (merged into main)
      shipped                                      f71c9b2

  T/code/l-wt  (merged into origin/main)
      free-l                                       2a7cbba

  7 branch(es) in 6 repo(s).

'
EXPECTED_NOTES='[warn]  T/code/d-detached: detached HEAD — left alone
[warn]  T/code/e-rebase: rebase in progress — left alone
[warn]  T/code/i-stale: no origin/trunk2 — measured against the local trunk2 instead
[warn]  T/code/j-local: no origin/main — measured against the local main instead
[warn]  T/code/k-unborn: no main or master branch
[info]  Dry run — nothing was deleted.'
for j in 1 4; do
    out="$(bash "$AM" tidy --dry-run --jobs "$j" 2>"$T/err" | norm; echo x)"; out="${out%x}"
    check "tidy --dry-run --jobs ${j}: the same plan"      same "$out" "$EXPECTED_PLAN"
    check "  and the same notes"                           same "$(sed -E 's/^[0-9T:Z-]+ //' "$T/err" | norm)" "$EXPECTED_NOTES"
done

echo "## 3. fewer git calls"
# A git that logs every call made inside a repository (-C).
mkdir -p "$T/gw"; realgit="$(command -v git)"
printf '#!/bin/sh\n[ "$1" = -C ] && echo "$*" >> "%s/calls"\nexec "%s" "$@"\n' "$T" "$realgit" > "$T/gw/git"; chmod +x "$T/gw/git"
calls() { : > "$T/calls"; PATH="$T/gw:$PATH" bash "$AM" "$@" >/dev/null 2>&1; wc -l < "$T/calls" | tr -d ' '; }
# Six plain repositories: the common case, a clean trunk and nothing else.
P="$T/plain"; mkdir -p "$P"
for n in p1 p2 p3 p4 p5 p6; do mk "$n"; mv "$R/$n" "$P/$n"; done
printf 'onboarded=1\nroot=%s\n' "$P" > "$T/p.conf"
export ASTROMECH_CONFIG="$T/p.conf"
n=$(calls status --jobs 1)
check "status: 3 git calls per plain repo, not 15 (${n} for 6)"      [ "$n" -le 18 ]
n=$(calls status --jobs 4)
check "  the same with --jobs 4 (${n})"                               [ "$n" -le 18 ]
check "  one rev-parse, one status, one for-each-ref each"            bash -c "[ \"\$(awk '{print \$3}' '$T/calls' | sort | uniq -c | awk '{print \$1}' | sort -u)\" = 6 ]"
n=$(calls tidy --dry-run --jobs 1)
check "tidy's plan: 2 per plain repo (${n} for 6)"                    [ "$n" -le 12 ]
n=$(calls maintain --dry-run --jobs 1)
check "maintain --dry-run: 4 per plain repo, its stash count included (${n} for 6)" [ "$n" -le 24 ]
export ASTROMECH_CONFIG="$T/c.conf"
n=$(calls status --jobs 1)
# Busier repos cost more (a worktree list and a --merged per repo with
# candidates, a stash list): still under a third of the previous 186.
check "status over the mixed tree: under 5 a repo (${n} for 12)"     [ "$n" -le 60 ]
# Status is read-only in its jobs too (Kamino item 142).
printf '#!/bin/sh\n[ "$1" = -C ] && printf "%%s\\n" "${GIT_OPTIONAL_LOCKS-unset}" >> "%s/optlocks"\nexec "%s" "$@"\n' "$T" "$realgit" > "$T/gw/git"
: > "$T/optlocks"; PATH="$T/gw:$PATH" bash "$AM" status --jobs 4 >/dev/null 2>&1
check "status's jobs run git with GIT_OPTIONAL_LOCKS=0 only"          bash -c "[ -s '$T/optlocks' ] && [ -z \"\$(grep -vx 0 '$T/optlocks')\" ]"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
