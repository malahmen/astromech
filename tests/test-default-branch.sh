#!/usr/bin/env bash
# _default_branch: which branch is the trunk, in the orders that matter.
#
# The case this exists for: a repository mid-rename — local 'master', 'main'
# only on origin — was told 'main' was its default, so 'master' was treated as
# a feature branch, a dirty tree was wip-committed onto it, and the run
# switched away. The next push published the wip commit.
#
# No network: file:// remotes only.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

# mkrepo <clone> <branch> — bare origin on <branch>, cloned, one commit.
mkrepo() {
    local dst="$1" b="${2:-main}" bare="$T/remotes/${1//\//_}.git"
    git init -q --bare -b "$b" "$bare"
    git clone -q "$bare" "$dst" 2>/dev/null
    git -C "$dst" checkout -q -b "$b" 2>/dev/null || true
    echo base > "$dst/f"; git -C "$dst" add f; git -C "$dst" commit -qm base
    git -C "$dst" push -q origin "$b"
}
# default <repo> — what the engine resolves, read through a sourced copy so the
# function is tested rather than inferred from behaviour.
default() {
    bash -c '
        set -uo pipefail
        _current_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }
        eval "$(sed -n "/^_default_branch() {/,/^}/p" "$1")"
        _default_branch "$2"; printf "|rc=%s" "$?"
    ' _ "$AM" "$1"
}

R="$T/code"; mkdir -p "$R"

echo "## 1. a repository mid-rename: local master, main only on origin"
mkrepo "$R/renaming" master
# a rename in progress on the remote: main pushed, master still checked out
git -C "$R/renaming" push -q origin master:main
git -C "$R/renaming" fetch -q origin
check "the trunk is still master, not main"  [ "$(default "$R/renaming")" = "master|rc=0" ]

echo "## 2. and the full run leaves it alone"
echo dirty > "$R/renaming/wip"
bash "$AM" add-root "$R" >/dev/null; bash "$AM" mark-onboarded >/dev/null
bash "$AM" maintain --repo "$R/renaming" >/dev/null 2>&1
check "still on master"                      [ "$(git -C "$R/renaming" symbolic-ref --short -q HEAD)" = master ]
check "no wip commit was made"               bash -c "! git -C '$R/renaming' log --oneline -1 | grep -q 'wip: auto-commit'"
# On the trunk a dirty tree is STASHED, which is the designed behaviour — the
# point is that nothing was committed to master and the work is recoverable.
check "the change is in the stash, not lost" bash -c "git -C '$R/renaming' stash list | grep -q 'astromech: before pull'"

echo "## 3. origin/HEAD is believed when it is valid"
mkrepo "$R/normal" main
check "main from origin/HEAD"                [ "$(default "$R/normal")" = "main|rc=0" ]
mkrepo "$R/legacy" master
check "master from origin/HEAD"              [ "$(default "$R/legacy")" = "master|rc=0" ]

echo "## 4. a stale origin/HEAD is not believed"
mkrepo "$R/stale" main
git -C "$R/stale" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
check "falls through to the real branch"     [ "$(default "$R/stale")" = "main|rc=0" ]

echo "## 5. with no origin/HEAD at all"
mkrepo "$R/nohead" master
git -C "$R/nohead" update-ref -d refs/remotes/origin/HEAD 2>/dev/null || \
    git -C "$R/nohead" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
check "the checked-out trunk wins"           [ "$(default "$R/nohead")" = "master|rc=0" ]
git -C "$R/nohead" checkout -q -b feature
check "a feature branch defers to local main/master" [ "$(default "$R/nohead")" = "master|rc=0" ]

echo "## 6. neither branch exists"
mkrepo "$R/odd" develop
git -C "$R/odd" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
check "no trunk is an error, not a guess"    bash -c "[ \"\$(bash -c '
        set -uo pipefail
        _current_branch() { git -C \"\$1\" symbolic-ref --short -q HEAD 2>/dev/null; }
        eval \"\$(sed -n \"/^_default_branch() {/,/^}/p\" \"\$1\")\"
        _default_branch \"\$2\" >/dev/null; printf \"rc=%s\" \"\$?\"
    ' _ '$AM' '$R/odd')\" = 'rc=1' ]"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
