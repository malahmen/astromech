#!/usr/bin/env bash
# tidy: which local branches are listed, which are deleted, and what it takes
# to get it to delete anything.
#
# The property every check here is really about: a branch is deletable only
# when the TRUNK ON ORIGIN already contains it. Measuring against the local
# trunk instead is the mistake that loses work — a local main carrying commits
# that were never pushed would call a branch merged on the strength of a merge
# nobody else has. The 'ahead' repo below is that case, and tidy must refuse it
# even though `git branch -d` would happily delete it.
#
# No network: file:// remotes only. No terminal either, which is the point of
# half of it — setsid detaches from the controlling terminal so the confirmation
# gate can be observed refusing, and a forked pty is used where the question
# itself has to be answered.
# shellcheck disable=SC2016
# The single quotes around every `bash -c` body are the point: the child must
# expand $OUT/$ERR itself, from the environment, which is why they are
# exported. Double-quoting them here would interpolate a whole captured report
# into a command line. A directive covers only the next COMMAND, so this is
# file-scoped and has to sit above the first one.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
have()  { git -C "$1" show-ref --verify -q "refs/heads/$2"; }
gone()  { ! git -C "$1" show-ref --verify -q "refs/heads/$2"; }

R="$T/code"; mkdir -p "$R"

# ---- fixtures ---------------------------------------------------------------
# mk <name> — a bare origin on main, cloned, one commit, origin/HEAD set.
mk() {
    local n="$1" bare c
    bare="$T/remotes/${n}.git"; c="$R/$n"
    git init -q --bare -b main "$bare"
    git clone -q "$bare" "$c" 2>/dev/null
    git -C "$c" symbolic-ref HEAD refs/heads/main
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" push -q -u origin main
    git -C "$c" remote set-head origin main
}
# br <repo> <branch> — one commit on a new branch, then back to main.
br() {
    git -C "$1" checkout -q -b "$2"
    printf '%s\n' "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$2"
    git -C "$1" checkout -q main
}
# mergeto <repo> <branch> — merge into main and push, so origin/main holds it.
mergeto() { git -C "$1" merge -q --no-ff -m "merge $2" "$2"; git -C "$1" push -q origin main; }

# plain: one branch origin/main holds, one it does not.
mk plain;    br "$R/plain" merged; mergeto "$R/plain" merged; br "$R/plain" unmerged

# behind: origin/main holds 'past', the LOCAL main does not, and 'past' has no
# upstream — so the plan contains it and git's own -d test still refuses it.
mk behind;   br "$R/behind" past;  mergeto "$R/behind" past
git -C "$R/behind" reset -q --hard HEAD~1
git -C "$R/behind" fetch -q origin
# behind2: the same, kept for the maintain --tidy run, which pulls first.
mk behind2;  br "$R/behind2" later; mergeto "$R/behind2" later
git -C "$R/behind2" reset -q --hard HEAD~1
git -C "$R/behind2" fetch -q origin

# ahead: 'localonly' is merged into the LOCAL main only — never pushed.
mk ahead;    br "$R/ahead" localonly
git -C "$R/ahead" merge -q --no-ff -m "merge localonly" localonly

# onbranch: a merged branch that happens to be checked out.
mk onbranch; br "$R/onbranch" current; mergeto "$R/onbranch" current
git -C "$R/onbranch" checkout -q current

# wt: a merged branch checked out in a second worktree, kept outside the root
# so the walk does not discover it as a repo of its own.
mk wt;       br "$R/wt" parked; mergeto "$R/wt" parked
git -C "$R/wt" worktree add -q "$T/wt-extra" parked

# noremote: no origin at all, so the local trunk is the only yardstick there is.
mkdir -p "$R/noremote"; git init -q -b main "$R/noremote"
echo base > "$R/noremote/f"; git -C "$R/noremote" add f; git -C "$R/noremote" commit -qm base
br "$R/noremote" shipped; git -C "$R/noremote" merge -q --no-ff -m "merge shipped" shipped

# rebasing: the in-progress guard. The directory is what _in_progress looks at.
mk rebasing; br "$R/rebasing" stuck; mergeto "$R/rebasing" stuck
mkdir -p "$R/rebasing/.git/rebase-merge"

bash "$AM" add-root "$R" >/dev/null 2>&1
bash "$AM" mark-onboarded >/dev/null 2>&1

# ---- invocation helpers -----------------------------------------------------
# run <args...> — OUT = stdout, ERR = stderr, RC = status. Safe for any form
# that cannot prompt (--dry-run, --yes).
# Exported because several checks read them from a `bash -c` child, which sees
# only the environment. An assertion that silently read an unset OUT would pass.
export OUT="" ERR="" RC=0
run() { OUT="$(bash "$AM" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
# norun <args...> — the same, with no controlling terminal, for the forms that
# WOULD prompt: the gate has to be seen refusing rather than hanging the suite.
norun() { OUT="$(setsid --wait bash "$AM" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }

export BEHIND2="$R/behind2"
HAVE_SETSID=0; setsid --wait true 2>/dev/null && HAVE_SETSID=1
HAVE_PTY=0;    python3 -c 'import pty' 2>/dev/null && HAVE_PTY=1

echo "## 1. the prediction list"
run tidy --dry-run
check "lists a branch origin/main contains"   bash -c 'grep -qw merged <<<"$OUT"'
check "  with the repo it is in"              has "plain" "$OUT"
check "  and its short sha for recovery"      bash -c '[[ "$OUT" =~ merged[[:space:]]+[0-9a-f]{7} ]]'
check "  naming what it measured against"     has "merged into origin/main" "$OUT"
check "does NOT list an unmerged branch"      bash -c '! grep -qw unmerged <<<"$OUT"'
check "does NOT list the trunk itself"        bash -c '! grep -qE "^ +main " <<<"$OUT"'
check "the list is on stdout, not stderr"     bash -c '! grep -qw merged <<<"$ERR"'
check "a dry run exits 0"                     test "$RC" -eq 0
check "and deletes nothing"                   have "$R/plain" merged

echo "## 2. the branch has to be on ORIGIN's trunk, not just the local one"
check "a locally-merged-only branch is not listed" bash -c '! grep -qw localonly <<<"$OUT"'
check "  and survives"                        have "$R/ahead" localonly
check "  though git -d itself would take it"  git -C "$R/ahead" merge-base --is-ancestor localonly HEAD
check "a branch only origin/main holds IS listed"  bash -c 'grep -qw past <<<"$OUT"'

echo "## 3. branches git will not let go of"
check "a checked-out branch is not listed"    bash -c '! grep -qw current <<<"$OUT"'
check "a worktree-held branch is not listed"  bash -c '! grep -qw parked <<<"$OUT"'
check "a repo mid-rebase is reported"         has "rebase in progress" "$ERR"
check "  and its branch is not listed"        bash -c '! grep -qw stuck <<<"$OUT"'
check "no origin: the weaker yardstick is named" has "no origin/main" "$ERR"
check "  and its merged branch is still listed"  bash -c 'grep -qw shipped <<<"$OUT"'

echo "## 4. the gate"
if (( HAVE_SETSID )); then
    norun tidy
    check "no terminal and no --yes: refuses"     test "$RC" -ne 0
    check "  says why"                            has "no terminal to confirm on" "$ERR"
    check "  names both ways out"                 bash -c 'grep -q -- "--yes" <<<"$ERR" && grep -q -- "--dry-run" <<<"$ERR"'
    check "  and deletes nothing"                 have "$R/plain" merged
else
    echo "   SKIP - no setsid --wait: the no-terminal checks need a detached session"
fi

if (( HAVE_PTY )); then
    cat > "$T/ptyrun.py" <<'PY'
import os, pty, select, sys
ans = (os.environ.get("PTY_ANS", "") + "\n").encode()
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
os.write(fd, ans)
out = bytearray()
while True:
    if not select.select([fd], [], [], 30)[0]:
        break
    try:
        d = os.read(fd, 1024)
    except OSError:
        break
    if not d:
        break
    out.extend(d)
st = os.waitpid(pid, 0)[1]
sys.stdout.buffer.write(bytes(out)); sys.stdout.flush()
sys.exit(os.waitstatus_to_exitcode(st))
PY
    # A real controlling terminal, answered from the master side. pty.fork is
    # the only way to get one: /dev/tty is otherwise unopenable here, and a
    # pipe on stdin would exercise the EOF path instead of the question.
    ask() { PTY_ANS="$1" python3 "$T/ptyrun.py" bash "$AM" tidy --repo "$R/plain" 2>&1; }
    export out_n out_y
    out_n="$(ask n)"
    check "the question is actually asked"        has "Delete 1 merged branch(es)?" "$out_n"
    check "answering no deletes nothing"          have "$R/plain" merged
    check "  and says so"                         has "Declined" "$out_n"
    out_y="$(ask y)"
    check "answering yes deletes it"              gone "$R/plain" merged
    check "  reporting the sha it was at"         bash -c '[[ "$out_y" =~ deleted\ merged\ \(was\ [0-9a-f]{7}\) ]]'
    check "  and leaves the unmerged one"         have "$R/plain" unmerged
else
    echo "   SKIP - no python3 pty: answering the question needs a terminal"
fi

echo "## 5. --yes"
run tidy --repo "$R/onbranch" --yes
check "--yes needs no terminal"               test "$RC" -eq 0
check "the trunk survives"                    have "$R/onbranch" main
check "the checked-out branch survives"       have "$R/onbranch" current
run tidy --repo "$R/noremote" --yes
check "a repo with no origin still tidies"    gone "$R/noremote" shipped
check "  and its trunk survives"              have "$R/noremote" main

echo "## 6. a plan git refuses is reported, never forced"
run tidy --repo "$R/behind" --yes
check "the refusal is fatal to the run"       test "$RC" -ne 0
check "it is reported as REFUSED"             has "REFUSED" "$ERR"
check "  with the -D command spelled out"     has "branch -D past" "$ERR"
check "  and the branch is still there"       have "$R/behind" past

echo "## 7. maintain --tidy"
if (( HAVE_SETSID )); then
    norun maintain --repo "$R/behind2" --tidy
    check "no terminal and no --yes: refuses"     test "$RC" -ne 0
    check "  before maintaining anything"         bash -c '! git -C "$BEHIND2" merge-base --is-ancestor later main'
    check "  and points at tidy --dry-run"        has "tidy --dry-run" "$ERR"
fi
later_sha="$(git -C "$R/behind2" rev-parse later)"
run maintain --repo "$R/behind2" --tidy --yes
check "the pull happens first"                git -C "$R/behind2" merge-base --is-ancestor "$later_sha" main
check "  so the same branch is now deletable" gone "$R/behind2" later
check "  and the run succeeds"                test "$RC" -eq 0
check "it is counted in the summary"          has "Tidy: 1 branch(es) deleted" "$ERR"
run maintain --repo "$R/plain" --tidy --dry-run
check "maintain --tidy --dry-run only lists"  have "$R/plain" unmerged
check "  and asks nothing"                    bash -c '! grep -q "Delete .* merged" <<<"$ERR"'

echo "## 8. nothing to do"
run tidy --repo "$R/wt" --yes
check "a repo with nothing to tidy exits 0"   test "$RC" -eq 0
check "  and says so"                         has "Nothing to tidy" "$ERR"
check "tidy is in the help"                   bash -c 'bash "$AM" --help 2>&1 | grep -q "^  tidy "'

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
