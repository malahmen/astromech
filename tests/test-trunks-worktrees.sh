#!/usr/bin/env bash
# review-2026-10-23's findings on tidy, status and prune (Kamino items
# 140-142). No network: file:// remotes only.
#   - tidy never plans a long-lived branch, even when origin/HEAD names a
#     different trunk (git-flow) (140);
#   - a linked worktree under a root is part of its repository, not a second
#     one (141);
#   - the rest (142): a branch being rebased in another worktree, a detached
#     HEAD, a branch named like a tag, status naming a rebase, prune reading
#     an included value, and tidy only after a pull that worked.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# The run lock lives under $HOME (and TMPDIR is where older engines put it):
# both inside $T, so no run here touches the user's real lock.
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"; unset XDG_RUNTIME_DIR

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! has "$@"; }
have()  { git -C "$1" show-ref --verify -q "refs/heads/$2"; }
gone()  { ! git -C "$1" show-ref --verify -q "refs/heads/$2"; }
OUT=""; ERR=""; RC=0
run() { OUT="$(bash "$AM" "$@" 2>"$T/err" </dev/null)"; RC=$?; ERR="$(cat "$T/err")"; }

R="$T/code"; mkdir -p "$R"
# mk <name> [trunk] - a bare origin on <trunk> (default main), cloned, one commit.
mk() {
    local tr="${2:-main}" bare="$T/remotes/$1.git" c="$R/$1"
    git init -q --bare -b "$tr" "$bare"
    git clone -q "$bare" "$c" 2>/dev/null
    git -C "$c" symbolic-ref HEAD "refs/heads/$tr"
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" push -q -u origin "$tr"; git -C "$c" remote set-head origin "$tr"
}
br()      { git -C "$1" checkout -q -b "$2"; printf '%s\n' "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2"; git -C "$1" checkout -q "${3:-main}"; }
mergeto() { git -C "$1" merge -q --no-ff -m "merge $2" "$2"; git -C "$1" push -q origin "$(git -C "$1" symbolic-ref --short HEAD)"; }

# flow: git-flow, origin/HEAD -> develop. main, release/1.0 and stable sit
# behind develop, and a feature branch is merged into it.
mk flow develop
for b in main release/1.0 stable hotfix/fix1; do git -C "$R/flow" branch "$b" develop; done
br "$R/flow" feature develop; mergeto "$R/flow" feature

# wt: a linked worktree INSIDE the root, holding a merged branch.
mk wt; br "$R/wt" parked; mergeto "$R/wt" parked
git -C "$R/wt" worktree add -q "$R/wt-linked" parked

# rb: a merged branch being rebased in another worktree (detached there).
mk rb; br "$R/rb" rebasing; mergeto "$R/rb" rebasing
git -C "$R/rb" worktree add -q "$T/rb-wt" rebasing
gd="$(git -C "$T/rb-wt" rev-parse --absolute-git-dir)"; git -C "$T/rb-wt" checkout -q --detach
mkdir -p "$gd/rebase-merge"; echo refs/heads/rebasing > "$gd/rebase-merge/head-name"

# det: a repo on a detached HEAD, with a merged branch.
mk det; br "$R/det" done1; mergeto "$R/det" done1; git -C "$R/det" checkout -q --detach

# tagged: a merged branch sharing its name with a tag.
mk tagged; br "$R/tagged" v1; mergeto "$R/tagged" v1; git -C "$R/tagged" tag v1 main

# st: detached mid-rebase, for status.
mk st; git -C "$R/st" checkout -q --detach; mkdir -p "$R/st/.git/rebase-merge"

bash "$AM" add-root "$R" >/dev/null 2>&1
bash "$AM" mark-onboarded >/dev/null 2>&1

echo "== 140: long-lived branches are never planned =="
run tidy --dry-run --repo "$R/flow"
check "the merged feature branch is listed"     has "feature" "$OUT"
check "main (behind develop) is not"            bash -c '! grep -qE "^ +main " <<<"$1"' _ "$OUT"
check "release/1.0 is not"                      lacks "release/1.0" "$OUT"
check "stable is not"                           lacks "stable" "$OUT"
check "hotfix/* is not"                         lacks "hotfix/fix1" "$OUT"
run tidy --yes --repo "$R/flow"
check "tidy --yes deletes the feature branch"   gone "$R/flow" feature
check "...and leaves main"                      have "$R/flow" main

echo
echo "== 170: maintain never wip-commits on a long-lived branch =="
# gf: git-flow (origin/HEAD -> develop); main and release/2.0 tracked on origin.
# Each is checked out with uncommitted work, as a hotfix in progress would be.
for b in main release/2.0; do
    n="gf-${b//\//-}"; mk "$n" develop
    git -C "$R/$n" checkout -q -b "$b"; git -C "$R/$n" push -q -u origin "$b" 2>/dev/null
    git -C "$R/$n" remote set-head origin develop
    echo "hotfix in progress" > "$R/$n/f"
    before="$(git -C "$R/$n" rev-parse HEAD)"
    run maintain --dry-run --repo "$R/$n"
    check "$b: a dry run does not plan a commit"        lacks "would commit" "$ERR"
    run maintain --repo "$R/$n"
    check "$b: no commit lands on it"                   test "$(git -C "$R/$n" rev-parse "refs/heads/$b")" = "$before"
    check "$b: still checked out"                       test "$(git -C "$R/$n" symbolic-ref --short HEAD)" = "$b"
    check "$b: the work is still in the working tree"   test -n "$(git -C "$R/$n" status --porcelain)"
    check "$b: skipped, and says why"                   has "long-lived branch '$b'" "$ERR"
    check "$b: a skip, not a failure (exit 0)"          test "$RC" -eq 0
done

echo
echo "== 141: a linked worktree is part of its repository =="
run repos
check "the worktree is not listed as a repo"    lacks "wt-linked" "$OUT"
check "its repository is"                       has "$R/wt" "$OUT"
run tidy --yes
check "tidy over everything exits 0"            test "$RC" -eq 0
check "...with nothing refused"                 lacks "REFUSED" "$ERR"
check "the branch the worktree holds stays"     have "$R/wt" parked

echo
echo "== 142: the rest =="
check "a branch being rebased elsewhere is left alone" have "$R/rb" rebasing
check "a detached HEAD repo is left alone"      have "$R/det" done1
check "...and said so"                          has "detached HEAD" "$ERR"
check "a branch named like a tag is tidied"     gone "$R/tagged" v1
check "...and the tag stays"                    git -C "$R/tagged" show-ref --verify -q refs/tags/v1
run status
check "status names a rebase, not just detached" has "(rebase)" "$OUT"
check "status does not list the worktree twice" test "$(grep -c "wt" <<<"$OUT")" -le 1

G="$T/gitconfig"; printf '[include]\n\tpath = %s/inc\n' "$T" > "$G"; printf '[fetch]\n\tprune = true\n' > "$T/inc"
GIT_CONFIG_GLOBAL="$G" run prune
check "prune reads a value from an included file" has "fetch.prune=true" "$OUT"
: > "$G"
GIT_CONFIG_GLOBAL="$G" run prune on --dry-run
check "prune on --dry-run says unset, not empty" has "fetch.prune=unset" "$OUT"

# tidy only after a pull that worked: a merged branch, and an origin that is gone.
mk nopull; br "$R/nopull" shipped; mergeto "$R/nopull" shipped
git -C "$R/nopull" remote set-url origin "$T/remotes/missing.git"
run maintain --repo "$R/nopull" --tidy --yes
check "a failed pull fails the run"             test "$RC" -ne 0
check "...and tidies nothing"                   have "$R/nopull" shipped

echo
(( FAILS == 0 )) && echo "test-trunks-worktrees: all checks passed" || { echo "test-trunks-worktrees: ${FAILS} check(s) failed"; exit 1; }
