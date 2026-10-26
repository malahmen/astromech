#!/usr/bin/env bash
# A stale index.lock must fail ONE repo, not the run — and two maintenance
# runs must not interleave. No network: file:// remotes only.
#
# Usage: tests/test-locked.sh    (or ASTROMECH=/path/to/astromech.sh ...)
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
# 'a' sorts before 'b', so the locked repo is reached FIRST: the point is that
# the run continues past it.
mkrepo "$R/a-locked"
mkrepo "$R/b-normal"
bash "$AM" add-root "$R" >/dev/null
bash "$AM" mark-onboarded >/dev/null

# a-locked: dirty work on a feature branch, and a lock nothing owns — exactly
# what an interrupted git leaves behind.
git -C "$R/a-locked" checkout -q -b feature
echo work > "$R/a-locked/new"
: > "$R/a-locked/.git/index.lock"

# b-normal: clean on main, with something to pull.
upstream "$R/b-normal" main g ahead

out="$(bash "$AM" maintain 2>&1)"; rc=$?

echo "## a stale index.lock fails one repo, not the run"
# 1, not 0: '(( n_fail == 0 ))' is maintain's contract, so a failed repo is
# meant to be visible in the exit status. 128 is the thing being fixed — git
# aborting the run, with no summary and the rest of the repos untouched.
check "exits 1 (a repo failed), not 128"     [ "$rc" -eq 1 ]
check "the summary is still printed"         grep -q "failed" <<<"$out"
check "the locked repo is reported failed"   grep -qi "add -A failed" <<<"$out"
check "the lock is left for a human"         [ -e "$R/a-locked/.git/index.lock" ]
check "the locked repo was not committed"    [ -n "$(git -C "$R/a-locked" status --porcelain)" ]
check "the next repo was still maintained"   [ -f "$R/b-normal/g" ]

echo "## the run lock"
LOCK="$HOME/.local/state/astromech/run.lock"
# A holder that is alive: refuse.
sleep 30 & holder=$!
mkdir -p "${LOCK%/*}"; printf '%s\n' "$holder" > "$LOCK"
out2="$(bash "$AM" maintain 2>&1)"; rc2=$?
check "a live lock holder is respected"      [ "$rc2" -ne 0 ]
check "  and says so"                        grep -qi "in progress" <<<"$out2"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# A holder that is gone: take it over rather than block maintenance forever.
printf '%s\n' "$holder" > "$LOCK"
out3="$(bash "$AM" maintain 2>&1)"
check "a dead holder's lock is reclaimed"    grep -q "Summary:" <<<"$out3"
check "  and it is reported"                 grep -qi "stale run lock" <<<"$out3"
check "the lock is released afterwards"      [ ! -e "$LOCK" ]

echo "## one lock per user, whatever the environment (Kamino item 193)"
# cron sets no XDG_RUNTIME_DIR, a desktop session does: the two runs used to
# take two different locks and exclude nothing.
sleep 30 & holder=$!
printf '%s\n' "$holder" > "$LOCK"
out4="$(env -u XDG_RUNTIME_DIR bash "$AM" maintain 2>&1)"; rc4=$?
check "a run without XDG_RUNTIME_DIR (cron) is refused"   [ "$rc4" -ne 0 ]
check "  because of the lock"                             grep -q "in progress" <<<"$out4"
mkdir -p "$T/xdg"
out5="$(XDG_RUNTIME_DIR="$T/xdg" bash "$AM" maintain 2>&1)"; rc5=$?
check "a run with XDG_RUNTIME_DIR (desktop) is refused"   [ "$rc5" -ne 0 ]
check "  because of the lock"                             grep -q "in progress" <<<"$out5"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -f "$LOCK"

echo "## the lock never exists without its pid (Kamino item 193)"
# A mkdir that, once, pauses for a second after doing its work: whatever the
# engine creates with it, a lock that is visible before its pid is written
# stays that way for the whole second, and a second run arriving then must not
# read it as stale and remove it from under its holder.
stub="$T/stub"; mkdir -p "$stub"; realmkdir="$(command -v mkdir)"
cat > "$stub/mkdir" <<STUB
#!/usr/bin/env bash
"$realmkdir" "\$@"; rc=\$?
case "\$*" in *"$T/"*) if rm "$T/pause-once" 2>/dev/null; then sleep 1; fi ;; esac
exit \$rc
STUB
chmod +x "$stub/mkdir"; : > "$T/pause-once"
PATH="$stub:$PATH" bash "$AM" maintain > "$T/a.out" 2>&1 & first=$!
for _ in $(seq 50); do [ -e "$T/pause-once" ] || break; sleep 0.1; done
PATH="$stub:$PATH" bash "$AM" maintain > "$T/b.out" 2>&1
wait "$first"
check "neither run calls the other's lock stale"          bash -c '! grep -qi "stale run lock" "$1" "$2"' _ "$T/a.out" "$T/b.out"
check "no lock is left behind"                            [ ! -e "$LOCK" ]

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
