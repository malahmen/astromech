#!/usr/bin/env bash
# prune: the global toggle, and the overrides that quietly beat it.
#
# Everything here WRITES to a global git config, so the first thing it does is
# prove that git honours $GIT_CONFIG_GLOBAL (2.32+) and bail out if it does
# not. The real ~/.gitconfig is not an acceptable place to discover that.
#
# shellcheck disable=SC2016
# The single quotes around every `bash -c` body are the point: the child must
# expand $OUT/$ERR itself, from the environment, which is why they are
# exported. A directive covers only the next COMMAND, so this is file-scoped
# and has to sit above the first one.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
export ASTROMECH_CONFIG="$T/cfg/astromech.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1
export XDG_RUNTIME_DIR="$T/run"; mkdir -p "$XDG_RUNTIME_DIR"

export GCONF="$T/gitconfig"; export GIT_CONFIG_GLOBAL="$GCONF"; : > "$GCONF"
git config --global astromech.probe yes 2>/dev/null
if [[ "$(git config --global --get astromech.probe 2>/dev/null)" != yes ]] || ! grep -q astromech "$GCONF"; then
    echo "SKIP - GIT_CONFIG_GLOBAL is not honoured by $(git --version); refusing to write to the real config" >&2
    exit 0
fi
git config --global --unset astromech.probe

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

export OUT="" ERR="" RC=0
run() { OUT="$(bash "$AM" "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"; }
gval() { git config --global --get fetch.prune 2>/dev/null || true; }
# ovr <repo-suffix> <key> <value> — is that override line in the report?
# Tab-delimited, so the field boundaries are asserted too, and built from
# $'\t' rather than grep -P, which BSD grep does not have.
TAB=$'\t'
ovr() { grep -q "^override=.*/${1}${TAB}${2}${TAB}${3}$" <<<"$OUT"; }

R="$T/code"; mkdir -p "$R"
mkrepo() {
    local n="$1" c
    c="$R/$n"; mkdir -p "$c"
    git init -q -b main "$c"
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" remote add origin "$T/remotes/${n}.git"
}
mkrepo clean
mkrepo offlocal; git -C "$R/offlocal" config --local fetch.prune false
mkrepo offremote; git -C "$R/offremote" config --local remote.origin.prune false
bash "$AM" add-root "$R" >/dev/null 2>&1

echo "## 1. show, with nothing set"
run prune
check "the value is reported on stdout"       bash -c '[[ "$OUT" == *"fetch.prune=unset"* ]]'
check "exits 0"                               test "$RC" -eq 0
check "says git's default is off"             has "default is off" "$ERR"
check "names what it DOES prune"              has "stale origin/* remote-tracking refs" "$ERR"
check "  and that maintain's pull does it"    has "pull --rebase' is a fetch" "$ERR"
check "names what it does NOT: local branches" has "local branches" "$ERR"
check "  pointing at tidy for those"          has "astromech.sh tidy" "$ERR"
check "  and saying no git setting does it"   has "No git setting deletes those" "$ERR"
check "mentions fetch.pruneTags as untouched" has "fetch.pruneTags" "$ERR"
check "offers the way to turn it on"          has "prune on" "$ERR"
check "the explanation is NOT on stdout"      bash -c '! grep -q "remote-tracking" <<<"$OUT"'

echo "## 2. the overrides that beat a global setting"
check "a repo-local fetch.prune is reported"  ovr offlocal fetch.prune false
check "remote.origin.prune is reported too"   ovr offremote remote.origin.prune false
check "a repo setting neither is not"         bash -c '! grep -q "clean" <<<"$OUT"'
check "and it says they beat the global one"  has "beat the global setting" "$ERR"
check "counted"                               has "overridden locally in 2 place(s)" "$ERR"

echo "## 3. the toggle writes, and says the way back"
run prune on
check "exits 0"                               test "$RC" -eq 0
check "the global config now says true"       test "$(gval)" = true
check "the transition is reported"            has "unset -> true" "$ERR"
check "the undo is an --unset, as it was"     has "git config --global --unset fetch.prune" "$ERR"
check "the read-back is on stdout"            bash -c '[[ "$OUT" == *"fetch.prune=true"* ]]'
check "the change does NOT re-explain"      bash -c '! grep -q "stale origin/\* remote-tracking refs" <<<"$ERR"'

echo "## 4. a no-op is a no-op"
run prune on
check "says it was already on"                has "already true" "$ERR"
check "does not claim to have changed it"     bash -c '! grep -q -- "-> true" <<<"$ERR"'
check "and still reports the value"           bash -c '[[ "$OUT" == *"fetch.prune=true"* ]]'
check "show no longer offers to turn it on"   bash -c '! bash "$AM" prune 2>&1 >/dev/null | grep -q "Turn it on"'

echo "## 5. off, and the undo names the real previous value"
run prune off
check "the global config now says false"      test "$(gval)" = false
check "the transition is reported"            has "true -> false" "$ERR"
check "the undo restores what was there"      has "git config --global fetch.prune true" "$ERR"
run prune
check "show calls it explicitly OFF"          has "explicitly OFF" "$ERR"

echo "## 6. --dry-run writes nothing"
run prune on --dry-run
check "it says what it would do"               has "would set fetch.prune=true" "$ERR"
check "  and what it is now"                   has "it is false now" "$ERR"
check "the config is untouched"                test "$(gval)" = false
check "the read-back shows the UNCHANGED value" bash -c '[[ "$OUT" == *"fetch.prune=false"* ]]'

echo "## 7. bad input"
run prune maybe
check "an unknown argument fails"             test "$RC" -ne 0
check "  naming what is accepted"             bash -c 'grep -q "'"'"'on'"'"'" <<<"$ERR" && grep -q "'"'"'off'"'"'" <<<"$ERR"'
check "  and quoting what it got"             has "got 'maybe'" "$ERR"
run prune on off
check "two arguments fail"                    test "$RC" -ne 0
check "nothing was written"                   test "$(gval)" = false

echo "## 8. a non-boolean value already in the config"
git config --global fetch.prune yes
run prune
check "'yes' is read as on"                   bash -c '! grep -q "explicitly OFF" <<<"$ERR"'
check "  and reported verbatim on stdout"     bash -c '[[ "$OUT" == *"fetch.prune=yes"* ]]'
run prune on
check "  so turning it on is a no-op"         has "already true" "$ERR"
check "  leaving the value as it was"         test "$(gval)" = yes

echo "## 9. no roots configured"
ASTROMECH_CONFIG="$T/empty.conf" run prune
check "still reports the global value"        bash -c '[[ "$OUT" == *"fetch.prune=yes"* ]]'
check "  and says why it scanned nothing"     has "No roots configured" "$ERR"
check "  without failing"                     test "$RC" -eq 0
check "prune is in the help"                  bash -c 'bash "$AM" --help 2>&1 | grep -q "^  prune "'

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
