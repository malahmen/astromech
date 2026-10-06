#!/usr/bin/env bash
# End-to-end test for astromech.sh against file:// bare remotes — no network.
# Covers config (roots, ignores, onboarding), recursive discovery, and every
# maintain path: feature-branch commit + checkout, stash on main, master as the
# default, a conflicting rebase left in place, the skip guards, and dry-run.
#
# Usage: tests/test-local.sh            # uses ../astromech.sh
#        ASTROMECH=/path/to/astromech.sh tests/test-local.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"   # macOS: /var → /private/var, match what the engine stores
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # no user hooks/signing/aliases
A() { bash "$AM" "$@" 2> >(sed 's/^[^ ]*Z //' >> "$T/err.log"); }
Arun() { : > "$T/last.out"; bash "$AM" "$@" > "$T/last.out" 2>&1; }

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
said()  { grep -q -- "$1" "$T/last.out"; }
br()    { git -C "$1" symbolic-ref --short -q HEAD; }
clean() { [[ -z "$(git -C "$1" status --porcelain)" ]]; }

# mkrepo <clone-path> [default-branch] — bare origin + clone with one commit.
mkrepo() {
    local dst="$1" b="${2:-main}" bare="$T/remotes/${1//\//_}.git"
    git init -q --bare -b "$b" "$bare"
    git clone -q "$bare" "$dst" 2>/dev/null
    git -C "$dst" checkout -q -b "$b" 2>/dev/null || true
    echo base > "$dst/f"; git -C "$dst" add f; git -C "$dst" commit -qm base; git -C "$dst" push -q origin "$b"
}
# upstream <clone-path> <branch> <file> <content> — a commit lands on the remote.
upstream() {
    local w="$T/up-$RANDOM"
    git clone -q "$(git -C "$1" remote get-url origin)" "$w" 2>/dev/null
    git -C "$w" checkout -q "$2"; echo "$4" > "$w/$3"; git -C "$w" add "$3"
    git -C "$w" commit -qm "up $3"; git -C "$w" push -q origin "$2"; rm -rf "$w"
}

R1="$T/code"; R2="$T/work"
mkdir -p "$R1/group" "$R1/archive" "$R1/plain/deeper" "$R2"
mkrepo "$R1/feat-repo"
mkrepo "$R1/dirty-main"
mkrepo "$R1/group/nested"
mkrepo "$R1/archive/old"                 # under an ignored folder → never touched
mkrepo "$R1/conflict"
mkrepo "$R1/legacy" master
mkrepo "$R1/detached"
mkrepo "$R1/develop-only" develop
mkrepo "$R2/other"
mkrepo "$R1/feat-repo/vendor/inner"      # repo inside a repo → not discovered
echo "vendor/" > "$R1/feat-repo/.gitignore"; git -C "$R1/feat-repo" add .gitignore
git -C "$R1/feat-repo" commit -qm ignore-vendor; git -C "$R1/feat-repo" push -q origin main

echo "## 1. config: roots, children, ignores, onboarding"
check "fresh config reports onboarded=0" bash -c "bash '$AM' config | grep -qx onboarded=0"
A add-root "$R1" "$R2"
A add-root "$R1"                          # duplicate → warning, not a second entry
check "two roots, no duplicate" [ "$(bash "$AM" roots | wc -l | tr -d ' ')" = 2 ]
check "add-root refuses a missing folder" bash -c "! bash '$AM' add-root '$T/nope' 2>/dev/null"
check "children lists top-level folders" bash -c "bash '$AM' children '$R1' | cut -f1 | grep -qx archive"
A set-ignores "$R1" archive plain
check "set-ignores stored absolute paths" bash -c "bash '$AM' ignores | grep -qx '$R1/archive'"
check "children flags ignored folders" bash -c "bash '$AM' children '$R1' | grep -qx \$'archive\t1'"
check "set-ignores rejects nested names" bash -c "! bash '$AM' set-ignores '$R1' group/nested 2>/dev/null"
A set-ignores "$R1" archive                # replace: plain no longer ignored
check "set-ignores replaces the set" [ "$(bash "$AM" ignores | wc -l | tr -d ' ')" = 1 ]
A mark-onboarded
check "mark-onboarded persists" bash -c "bash '$AM' config | grep -qx onboarded=1"

echo "## 2. discovery"
repos="$(bash "$AM" repos 2>/dev/null | cut -f2)"
check "nested repo found recursively"  grep -qx "$R1/group/nested" <<< "$repos"
check "ignored folder's repo skipped"  bash -c "! grep -qx '$R1/archive/old' <<< '$repos'"
check "repo inside a repo not walked"  bash -c "! grep -qx '$R1/feat-repo/vendor/inner' <<< '$repos'"
check "second root discovered"         grep -qx "$R2/other" <<< "$repos"
bash "$AM" status > "$T/status.out" 2>/dev/null
check "status shows ignored folder"    grep -q "archive/  (ignored)" "$T/status.out"
check "status shows nested repo"       grep -q "group/nested" "$T/status.out"

echo "## 3. prepare repo states"
git -C "$R1/feat-repo" checkout -q -b feat/x; echo wip > "$R1/feat-repo/f"; echo new > "$R1/feat-repo/untracked"
upstream "$R1/feat-repo" main g upstream-g
echo local > "$R1/dirty-main/f"; echo u > "$R1/dirty-main/scratch"
upstream "$R1/dirty-main" main h upstream-h
echo mine > "$R1/conflict/f"; git -C "$R1/conflict" commit -qam mine
upstream "$R1/conflict" main f theirs
upstream "$R1/legacy" master l upstream-l
git -C "$R1/detached" checkout -q --detach HEAD
upstream "$R1/group/nested" main n upstream-n
upstream "$R1/archive/old" main o upstream-o

echo "## 4. dry run changes nothing"
Arun maintain --dry-run
check "dry run says it would commit"        said "would commit all changes on 'feat/x'"
check "feat-repo still on feat/x"           [ "$(br "$R1/feat-repo")" = feat/x ]
check "dirty-main still dirty, no stash"    bash -c "! git -C '$R1/dirty-main' stash list | grep -q . && [ -n \"\$(git -C '$R1/dirty-main' status --porcelain)\" ]"

echo "## 5. maintain"
Arun maintain; rc=$?
check "exit 1 because a repo failed"        [ "$rc" = 1 ]
check "feat/x got a wip commit"             bash -c "git -C '$R1/feat-repo' log -1 --format=%s feat/x | grep -q '^wip: auto-commit before astromech'"
check "untracked file committed on feat/x"  bash -c "git -C '$R1/feat-repo' ls-tree --name-only feat/x | grep -qx untracked"
check "feat-repo now on main, pulled"       bash -c "[ \"\$(git -C '$R1/feat-repo' symbolic-ref --short HEAD)\" = main ] && [ -f '$R1/feat-repo/g' ]"
check "feat/x not pushed"                   bash -c "! git -C '$R1/feat-repo' ls-remote --heads origin feat/x | grep -q ."
check "dirty-main stashed (untracked too)"  bash -c "git -C '$R1/dirty-main' stash list | grep -q 'astromech: before pull' && [ ! -e '$R1/dirty-main/scratch' ]"
check "dirty-main pulled, stash not popped" bash -c "[ -f '$R1/dirty-main/h' ] && [ \"\$(cat '$R1/dirty-main/f')\" = base ]"
check "conflict left mid-rebase"            test -d "$(git -C "$R1/conflict" rev-parse --absolute-git-dir)/rebase-merge" -o -d "$(git -C "$R1/conflict" rev-parse --absolute-git-dir)/rebase-apply"
check "conflict reported as FAILED"         said "FAILED .*conflict: pull --rebase stopped on a conflict"
check "master used when no main"            [ -f "$R1/legacy/l" ]
check "detached HEAD skipped"               said "detached: detached HEAD"
check "develop-only skipped"                said "develop-only: no main or master branch"
check "nested repo pulled"                  [ -f "$R1/group/nested/n" ]
check "ignored repo untouched (not pulled)" [ ! -e "$R1/archive/old/o" ]
check "second root maintained"              said "── other"
check "run continued past the conflict"    bash -c "awk '/── conflict/{c=1} c&&/── legacy/{f=1} END{exit !f}' '$T/last.out'"

echo "## 6. rerun: mid-rebase repo is skipped, not touched"
Arun maintain
check "in-progress rebase skipped"          said "conflict: rebase in progress"
check "clean main is a plain pull"          bash -c "grep -A3 '── feat-repo' '$T/last.out' | grep -q '\[ok\].*pulled' && ! grep -A3 '── feat-repo' '$T/last.out' | grep -qE 'committed|stashed'"

echo "## 7. --repo limits the run"
Arun maintain --repo "$R1/legacy"
check "only one repo maintained"            said "Maintaining 1 repo"
check "--repo rejects unknown repos"        bash -c "! bash '$AM' maintain --repo '$R1/archive/old' 2>/dev/null"

echo "## 8. remove-root drops its ignores"
A remove-root "$R1"
check "root removed"                        [ "$(bash "$AM" roots)" = "$R2" ]
check "its ignores removed"                 [ -z "$(bash "$AM" ignores)" ]
check "onboarded kept"                      bash -c "bash '$AM' config | grep -qx onboarded=1"

echo
if (( FAILS )); then echo "${FAILS} check(s) FAILED"; exit 1; fi
echo "all checks passed"
