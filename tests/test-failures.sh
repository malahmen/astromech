#!/usr/bin/env bash
# The paths where a step fails or the repo is not the usual shape: a hook that
# refuses the wip commit, a repo with both main and master, a tracked file named
# like the trunk, and tidy meeting a run already in progress.
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
said()  { grep -q -- "$1" "$T/last.out"; }
br()    { git -C "$1" symbolic-ref --short -q HEAD; }
Arun()  { bash "$AM" "$@" > "$T/last.out" 2>&1; }

# mkrepo <clone> [branch] — bare origin on <branch>, cloned, one commit.
mkrepo() {
    local dst="$1" b="${2:-main}" bare="$T/remotes/${1//\//_}.git"
    git init -q --bare -b "$b" "$bare"
    git clone -q "$bare" "$dst" 2>/dev/null
    git -C "$dst" checkout -q -b "$b" 2>/dev/null || true
    echo base > "$dst/f"; git -C "$dst" add f; git -C "$dst" commit -qm base; git -C "$dst" push -q origin "$b"
}
upstream() {
    local w="$T/up-$RANDOM"
    git clone -q "$(git -C "$1" remote get-url origin)" "$w" 2>/dev/null
    git -C "$w" checkout -q "$2"; echo "$4" > "$w/$3"; git -C "$w" add "$3"
    git -C "$w" commit -qm "up $3"; git -C "$w" push -q origin "$2"; rm -rf "$w"
}

R="$T/code"; mkdir -p "$R"

# a-hooked: work on a feature branch, and a pre-commit hook that refuses it.
mkrepo "$R/a-hooked"
git -C "$R/a-hooked" checkout -q -b feature
echo work > "$R/a-hooked/new"; echo changed > "$R/a-hooked/f"
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$R/a-hooked/.git/hooks/pre-commit"
chmod +x "$R/a-hooked/.git/hooks/pre-commit"

# b-both: main and master both on origin, no origin/HEAD, standing on master.
mkrepo "$R/b-both" master
git -C "$R/b-both" push -q origin master:main
git -C "$R/b-both" fetch -q origin
git -C "$R/b-both" branch -q main origin/main
git -C "$R/b-both" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null || true
upstream "$R/b-both" master m upstream-m
echo dirty > "$R/b-both/wip"

# c-named: a tracked file called 'main', and main only on origin — the one
# shape in which a bare 'git checkout main' is ambiguous.
mkrepo "$R/c-named"
echo x > "$R/c-named/main"; git -C "$R/c-named" add main; git -C "$R/c-named" commit -qm "a file named main"
git -C "$R/c-named" push -q origin main
git -C "$R/c-named" checkout -q -b feature
git -C "$R/c-named" branch -q -D main
upstream "$R/c-named" main n upstream-n

bash "$AM" add-root "$R" >/dev/null 2>&1; bash "$AM" mark-onboarded >/dev/null
Arun maintain; rc=$?

echo "## 1. a hook refuses the wip commit"
check "exits 1: a repo failed"                  [ "$rc" -eq 1 ]
check "reported as a failed commit"             said "FAILED .*a-hooked: commit on 'feature' failed"
check "git's reason is shown"                   said "hook says no"
check "still on the feature branch"             [ "$(br "$R/a-hooked")" = feature ]
check "nothing left staged"                     [ -z "$(git -C "$R/a-hooked" diff --cached --name-only)" ]
check "the work is still in the tree"           bash -c "[ -f '$R/a-hooked/new' ] && grep -qx changed '$R/a-hooked/f'"
check "no commit was made"                      [ "$(git -C "$R/a-hooked" rev-list --count HEAD)" -eq 1 ]

echo "## 2. main and master both exist"
check "master is the trunk it stands on"        [ "$(br "$R/b-both")" = master ]
check "the dirty tree was stashed, not committed" bash -c "git -C '$R/b-both' stash list | grep -q 'astromech: before pull' && ! git -C '$R/b-both' log --format=%s | grep -q wip:"
check "master was pulled"                       [ -f "$R/b-both/m" ]
# With both on origin, origin/HEAD decides. Set here rather than left to the
# pull above, because only newer git (2.48+) recreates it on fetch.
git -C "$R/b-both" remote set-head origin master
git -C "$R/b-both" checkout -q -b feature
echo more > "$R/b-both/g"
Arun maintain --repo "$R/b-both"
check "from a feature branch, origin's master, not main" [ "$(br "$R/b-both")" = master ]

echo "## 3. a tracked file named like the trunk"
check "checked out main, not refused"           [ "$(br "$R/c-named")" = main ]
check "and pulled it"                           [ -f "$R/c-named/n" ]
check "the summary does not list it"            bash -c "! grep -q 'c-named' <(grep -E 'FAILED|skipped' '$T/last.out')"

echo "## 4. tidy waits for a run in progress"
git -C "$R/c-named" branch -q done-branch main
LOCK="$XDG_RUNTIME_DIR/astromech-$(id -u).lock"
sleep 30 & holder=$!
mkdir -p "$LOCK"; printf '%s\n' "$holder" > "$LOCK/pid"
Arun tidy --yes; rc=$?
check "tidy refuses"                            [ "$rc" -ne 0 ]
check "  and says why"                          said "in progress"
check "  and deleted nothing"                   git -C "$R/c-named" show-ref --verify -q refs/heads/done-branch
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "the live holder's lock was left alone"   [ -d "$LOCK" ]
rm -r "$LOCK"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
