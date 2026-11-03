#!/usr/bin/env bash
# maintain --jobs N (Kamino item 238): several repos at once, with the report,
# the totals and the exit status of one at a time; repos sharing a git dir
# never at once; nothing that prompts, nothing that crashes, and no signal
# stopping the run without its lock released and its jobs gone.
#
# No network: file:// remotes, and a git/ssh/date/remote helper stubbed on PATH
# where a slow pull, a prompt or a crash has to be staged.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }

T=$(mktemp -d)
T="$(cd "$T" && pwd -P)"
# Whatever a stub left running (a hung pull, a prompt nobody answers) goes too.
cleanup() {
    local p
    for p in $(cat "$T"/pids.* 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# The run lock lives under $HOME: inside $T, so no run here touches the user's.
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"; unset XDG_RUNTIME_DIR GIT_SSH GIT_SSH_COMMAND GIT_TERMINAL_PROMPT GIT_ASKPASS SSH_ASKPASS
LOCK="$HOME/.local/state/astromech/run.lock"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

# mkrepo <clone> — bare origin on main, cloned, one commit.
mkrepo() {
    local dst="$1" bare="${1%/*}/../remotes/${1##*/}.git"
    mkdir -p "${bare%/*}"
    git init -q --bare -b main "$bare"
    git clone -q "$bare" "$dst" 2>/dev/null
    git -C "$dst" checkout -q -b main 2>/dev/null || true
    echo base > "$dst/f"; git -C "$dst" add f; git -C "$dst" commit -qm base; git -C "$dst" push -q origin main
}
upstream() {
    local w="$T/up-$RANDOM"
    git clone -q "$(git -C "$1" remote get-url origin)" "$w" 2>/dev/null
    echo "$3" > "$w/$2"; git -C "$w" add "$2"
    git -C "$w" commit -qm "up $2"; git -C "$w" push -q origin main; rm -rf "$w"
}
# setroot <dir> <config> — a config whose only root is <dir>.
setroot() { ASTROMECH_CONFIG="$2" bash "$AM" add-root "$1" >/dev/null 2>&1; ASTROMECH_CONFIG="$2" bash "$AM" mark-onboarded >/dev/null; }
now() { date +%s; }

# ---- stubs ------------------------------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB"; REALGIT="$(command -v git)"; REALDATE="$(command -v date)"
# git: on 'pull', logs "S|E <git dir>" to $FAKEGIT_LOG around the real pull,
# after $FAKEGIT_DELAY seconds ($FAKEGIT_SLOW_DELAY for a repo whose path
# contains $FAKEGIT_SLOW); with $FAKEGIT_HANG it never returns.
cat > "$STUB/git" <<STUB
#!/usr/bin/env bash
real="$REALGIT"; repo=""; sub=""; a=("\$@"); i=0
while (( i < \${#a[@]} )); do
    case "\${a[i]}" in -C) repo="\${a[i+1]}"; i=\$((i + 2)) ;; -c) i=\$((i + 2)) ;; -*) i=\$((i + 1)) ;; *) sub="\${a[i]}"; break ;; esac
done
if [[ "\$sub" == pull && -n "\${FAKEGIT_LOG:-}" ]]; then
    key="\$(cd "\$repo" && cd "\$("\$real" rev-parse --git-common-dir)" && pwd -P)"
    echo "S \$key" >> "\$FAKEGIT_LOG"
    if [[ -n "\${FAKEGIT_HANG:-}" ]]; then echo "\$\$" >> "$T/pids.git"; exec sleep 60; fi
    d="\${FAKEGIT_DELAY:-0}"; [[ -n "\${FAKEGIT_SLOW:-}" && "\$repo" == *"\$FAKEGIT_SLOW"* ]] && d="\${FAKEGIT_SLOW_DELAY:-2}"
    sleep "\$d"
    "\$real" "\$@"; rc=\$?
    echo "E \$key" >> "\$FAKEGIT_LOG"
    exit \$rc
fi
exec "\$real" "\$@"
STUB
# ssh: a prompt nobody answers unless BatchMode=yes, which fails at once the
# way a missing agent key does (as everything does with $FAKESSH_NOHANG).
# Logs its arguments.
cat > "$STUB/ssh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$T/ssh.args"
case " \$* " in *" BatchMode=yes "*) echo "Permission denied (publickey)." >&2; exit 255 ;; esac
[[ -n "\${FAKESSH_NOHANG:-}" ]] && { echo "Permission denied (publickey)." >&2; exit 255; }
echo "\$\$" >> "$T/pids.ssh"; exec sleep 20
STUB
# git-remote-askcred: an https remote that wants a username, the way git asks
# for one: refused at once under GIT_TERMINAL_PROMPT=0, otherwise it waits.
cat > "$STUB/git-remote-askcred" <<STUB
#!/usr/bin/env bash
if [[ "\${GIT_TERMINAL_PROMPT:-}" == 0 ]]; then
    echo "fatal: could not read Username for 'https://example.invalid': terminal prompts disabled" >&2; exit 128
fi
echo "\$\$" >> "$T/pids.cred"; exec sleep 20
STUB
chmod +x "$STUB/git" "$STUB/ssh" "$STUB/git-remote-askcred"
export PATH="$STUB:$PATH"

# ---- 1. the same report, in the same order ----------------------------------
# One fixture, copied: the copies differ only in their path, so after that is
# normalised (and the timestamps cut) --jobs 1 and --jobs 4 must print the
# same bytes. a-feature's pull is made the slowest, so later repos finish
# first under --jobs 4 and must still be printed after it.
X1="$T/x1"; mkdir -p "$X1/code"; C="$X1/code"
mkrepo "$C/a-feature"; upstream "$C/a-feature" g1 up
git -C "$C/a-feature" checkout -q -b feature; echo wip > "$C/a-feature/new"
mkrepo "$C/b-stash"; upstream "$C/b-stash" g2 up; echo dirty >> "$C/b-stash/f"
mkrepo "$C/c-detached"; git -C "$C/c-detached" checkout -q --detach
mkrepo "$C/d-hook"; git -C "$C/d-hook" checkout -q -b feature; echo w > "$C/d-hook/new"
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$C/d-hook/.git/hooks/pre-commit"; chmod +x "$C/d-hook/.git/hooks/pre-commit"
mkrepo "$C/e-tidy"
git -C "$C/e-tidy" push -q origin main:old
echo more > "$C/e-tidy/f"; git -C "$C/e-tidy" commit -qam more; git -C "$C/e-tidy" push -q origin main
git -C "$C/e-tidy" fetch -q origin
git -C "$C/e-tidy" branch -q done1; git -C "$C/e-tidy" branch -q done2
# contained in origin/main, but its own upstream (origin/old) does not hold it:
# git branch -d refuses it, and tidy reports REFUSED.
git -C "$C/e-tidy" branch -q stale; git -C "$C/e-tidy" branch -q -u origin/old stale
git -C "$C/e-tidy" checkout -q -b work; echo w > "$C/e-tidy/w"; git -C "$C/e-tidy" add w; git -C "$C/e-tidy" commit -qm work
git -C "$C/e-tidy" checkout -q main
mkrepo "$C/f-behind"; git -C "$C/f-behind" branch -q done3; upstream "$C/f-behind" g3 up
X2="$T/x2"; cp -a "$X1" "$X2"
for r in "$X2"/code/*; do git -C "$r" remote set-url origin "$X2/remotes/${r##*/}.git"; done
setroot "$X1/code" "$T/c1.conf"; setroot "$X2/code" "$T/c2.conf"
norm() { sed -E -e 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z //' -e "s#${X2}#X#g; s#${X1}#X#g" "$1" | grep -v 'repos at a time'; }

export FAKEGIT_LOG="$T/eq.log" FAKEGIT_SLOW=a-feature FAKEGIT_SLOW_DELAY=3
# stdout and stderr apart first (a dry run prints tidy's plan on stdout)...
ASTROMECH_CONFIG="$T/c1.conf" bash "$AM" maintain --tidy --dry-run --jobs 1 >"$T/d1.out" 2>"$T/d1.err"; drc1=$?
ASTROMECH_CONFIG="$T/c2.conf" bash "$AM" maintain --tidy --dry-run --jobs 4 >"$T/d4.out" 2>"$T/d4.err"; drc4=$?
# ...then the real thing, both streams in one file.
ASTROMECH_CONFIG="$T/c1.conf" bash "$AM" maintain --tidy --yes --jobs 1 >"$T/j1.all" 2>&1; rc1=$?
ASTROMECH_CONFIG="$T/c2.conf" bash "$AM" maintain --tidy --yes --jobs 4 >"$T/j4.all" 2>&1; rc4=$?
unset FAKEGIT_LOG FAKEGIT_SLOW FAKEGIT_SLOW_DELAY

echo "## 1. --jobs 4 reports exactly what --jobs 1 does"
check "--jobs 4 says it runs repos at once, once"        [ "$(grep -c 'repos at a time' "$T/j4.all")" -eq 1 ]
check "--jobs 1 does not"                                bash -c "! grep -q 'repos at a time' '$T/j1.all'"
check "same report, byte for byte (one stream)"          cmp -s <(norm "$T/j1.all") <(norm "$T/j4.all")
check "same stderr in a dry run (two streams)"           cmp -s <(norm "$T/d1.err") <(norm "$T/d4.err")
check "same stdout (tidy's plan) in a dry run"           cmp -s <(norm "$T/d1.out") <(norm "$T/d4.out")
check "  which is not empty"                             grep -q done1 "$T/d4.out"
check "same exit status (1: a repo failed)"              [ "$rc1/$rc4/$drc1" = "1/1/$drc4" ]
check "the sections are in repo order"                   [ "$(grep -oE '── [a-f]-[a-z]+' "$T/j4.all" | awk '{print $2}' | tr '\n' ' ')" = "a-feature b-stash c-detached d-hook e-tidy f-behind " ]
check "  although a-feature's pull finished last"        grep -q "^E $X2/code/a-feature/" <(grep '^E' "$T/eq.log" | tail -1)
sections=$(grep -c '── ' "$T/j4.all")
read -r ok sk fl < <(sed -nE 's/.*Summary: ([0-9]+) ok, ([0-9]+) skipped, ([0-9]+) failed\..*/\1 \2 \3/p' "$T/j4.all")
read -r del ref < <(sed -nE 's/.*Tidy: ([0-9]+) branch\(es\) deleted, ([0-9]+) refused\..*/\1 \2/p' "$T/j4.all")
check "totals add up to the repos: ${ok:-?}+${sk:-?}+${fl:-?} = ${sections}" [ "$(( ${ok:-0} + ${sk:-0} + ${fl:-0} ))/$sections" = "6/6" ]
check "  4 ok, 1 skipped, 1 failed"                      [ "${ok:-}/${sk:-}/${fl:-}" = "4/1/1" ]
check "tidy's counts add up: ${del:-?} deleted"          [ "${del:-x}/$(grep -c '\[info\]  deleted ' "$T/j4.all")" = "3/3" ]
check "  ${ref:-?} refused, each listed"                 [ "${ref:-x}/$(grep -c 'REFUSED ' "$T/j4.all")" = "1/1" ]
check "  and the same under --jobs 1"                    [ "$(grep -E 'Summary:|Tidy:' "$T/j1.all" | norm /dev/stdin)" = "$(grep -E 'Summary:|Tidy:' "$T/j4.all" | norm /dev/stdin)" ]
check "the work really was done under --jobs 4"          bash -c "[ -f '$X2/code/a-feature/g1' ] && [ -f '$X2/code/f-behind/g3' ] && ! git -C '$X2/code/e-tidy' show-ref -q --verify refs/heads/done1"
check "no buffers left behind"                           bash -c "[ -z \"\$(ls -A '$TMPDIR')\" ]"
check "the lock is released"                             [ ! -e "$LOCK" ]

echo "## 2. --jobs, the config and the default"
R="$T/s/code"; mkdir -p "$R"; for n in p1 p2 p3 p4; do mkrepo "$R/$n"; done
setroot "$R" "$T/s.conf"; export ASTROMECH_CONFIG="$T/s.conf"
out="$(bash "$AM" maintain 2>&1)"
check "the default runs repos at once"                   grep -q 'Up to 4 repos at a time' <<<"$out"
echo "jobs=1" >> "$T/s.conf"
out="$(bash "$AM" maintain 2>&1)"
check "jobs=1 in the config: one at a time"              bash -c "! grep -q 'repos at a time' <<<\"\$1\"" _ "$out"
check "  and config reports it"                          grep -qx 'jobs=1' <(bash "$AM" config 2>/dev/null)
out="$(bash "$AM" maintain --jobs 2 2>&1)"
check "--jobs beats the config"                          grep -q 'Up to 2 repos at a time' <<<"$out"
bash "$AM" add-root "$T" >/dev/null 2>&1; bash "$AM" remove-root "$T" >/dev/null 2>&1
check "the config keeps jobs= when it is rewritten"      grep -qx 'jobs=1' "$T/s.conf"
sed -i.bak 's/^jobs=1$/jobs=lots/' "$T/s.conf"
out="$(bash "$AM" maintain 2>&1)"; rc=$?
check "a bad jobs= is named, and the default used"       bash -c "grep -q 'jobs=lots is not a number' <<<\"\$1\" && grep -q 'Up to 4 repos' <<<\"\$1\"" _ "$out"
check "  and does not fail the run"                      [ "$rc" -eq 0 ]
for bad in 0 x -1 65; do
    bash "$AM" maintain --jobs "$bad" >/dev/null 2>&1; rc=$?
    check "--jobs ${bad} is refused"                     [ "$rc" -ne 0 ]
done
out="$(bash "$AM" maintain --jobs 8 --repo "$R/p2" 2>&1)"
check "one repo (--repo) runs as it always did"          bash -c "! grep -q 'repos at a time' <<<\"\$1\" && grep -q 'Summary: 1 ok' <<<\"\$1\"" _ "$out"
check "--help documents --jobs"                          bash -c "bash '$AM' --help 2>&1 | grep -q -- '--jobs N'"
unset ASTROMECH_CONFIG

echo "## 3. a run takes about as long as its slowest pull, not their sum"
for n in p1 p2 p3 p4; do upstream "$R/$n" "g-$n" up; done
export ASTROMECH_CONFIG="$T/s.conf"; sed -i.bak '/^jobs=/d' "$T/s.conf"
t0=$(now); FAKEGIT_LOG="$T/speed.log" FAKEGIT_DELAY=4 bash "$AM" maintain >"$T/speed.out" 2>&1; rc=$?; t1=$(now)
check "four 4-second pulls take under 11s, not 16s+ ($((t1 - t0))s)" [ $((t1 - t0)) -lt 11 ]
check "  and all four were pulled"                       bash -c "grep -q 'Summary: 4 ok' '$T/speed.out' && [ -f '$R/p4/g-p4' ]"
unset ASTROMECH_CONFIG

echo "## 4. repos whose git dirs are one or nested never run at once"
# x keeps its git dir inside a's .git, as a submodule does under the
# superproject's .git/modules; b is unrelated and should overlap with them.
N="$T/n/code"; mkdir -p "$N"
mkrepo "$N/a"; mkrepo "$N/b"
git init -q --bare -b main "$T/n/remotes/x.git"
mkdir -p "$N/a/.git/modules"; git clone -q --separate-git-dir "$N/a/.git/modules/x" "$T/n/remotes/x.git" "$N/x" 2>/dev/null
git -C "$N/x" checkout -q -b main 2>/dev/null; echo base > "$N/x/f"; git -C "$N/x" add f; git -C "$N/x" commit -qm base; git -C "$N/x" push -q origin main
for n in a b x; do upstream "$N/$n" "g-$n" up; done
setroot "$N" "$T/n.conf"
ASTROMECH_CONFIG="$T/n.conf" FAKEGIT_LOG="$T/nest.log" FAKEGIT_DELAY=1 bash "$AM" maintain --jobs 4 >"$T/nest.out" 2>&1; rc=$?
# Replays the S/E log: fails on a start while a related git dir is in flight;
# prints the most jobs ever in flight.
overlap() {
    awk '{ if ($1 == "S") { for (k in fl) if (fl[k] && (k == $2 || index($2, k "/") == 1 || index(k, $2 "/") == 1)) bad = 1
                            fl[$2] = 1; n++; if (n > max) max = n }
           else { fl[$2] = 0; n-- } }
         END { print max + 0; exit bad }' "$1"
}
no_overlap() { overlap "$1" >/dev/null; }
check "all three maintained"                             bash -c "grep -q 'Summary: 3 ok' '$T/nest.out' && [ -f '$N/x/g-x' ]"
check "a and x (git dir inside a's) never overlapped"    no_overlap "$T/nest.log"
check "  while b did run beside one of them"             [ "$(overlap "$T/nest.log")" -ge 2 ]

echo "## 5. nothing prompts: a repo that would ask fails instead of hanging"
P="$T/p/code"; mkdir -p "$P"; mkrepo "$P/a-ok"; mkrepo "$P/b-ssh"; mkrepo "$P/c-ok"
git -C "$P/b-ssh" remote set-url origin "fakehost:b-ssh.git"
setroot "$P" "$T/p.conf"; export ASTROMECH_CONFIG="$T/p.conf"
# deadline SECS OUT CMD... — runs CMD, killed after SECS; rc 124 then.
deadline() {
    local secs="$1" out="$2"; shift 2
    "$@" >"$out" 2>&1 & local p=$! n=0
    while kill -0 "$p" 2>/dev/null && (( n < secs * 10 )); do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$p" 2>/dev/null; then kill -TERM "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
    wait "$p"
}
: > "$T/ssh.args"
deadline 12 "$T/ssh.out" bash "$AM" maintain; rc=$?
check "an ssh remote that would prompt: run ends (rc ${rc}, not 124)" [ "$rc" -eq 1 ]
check "  that repo failed"                               grep -q 'FAILED .*b-ssh' "$T/ssh.out"
check "  with ssh's reason"                              grep -q 'Permission denied' "$T/ssh.out"
check "  the others were maintained"                     grep -q 'Summary: 2 ok, 0 skipped, 1 failed' "$T/ssh.out"
: > "$T/ssh.args"
GIT_SSH_COMMAND="ssh -o UserMarker=1" FAKESSH_NOHANG=1 deadline 12 "$T/ssh2.out" bash "$AM" maintain --repo "$P/b-ssh" --jobs 1
check "--jobs 1 leaves GIT_SSH_COMMAND as it is"         bash -c "grep -q UserMarker=1 '$T/ssh.args' && ! grep -q BatchMode '$T/ssh.args'"
: > "$T/ssh.args"
GIT_SSH_COMMAND="ssh -o UserMarker=1" deadline 12 "$T/ssh3.out" bash "$AM" maintain
check "GIT_SSH_COMMAND is kept, BatchMode added"         bash -c "grep -q 'UserMarker=1 -o BatchMode=yes' '$T/ssh.args'"
: > "$T/ssh.args"
git -C "$P/b-ssh" config core.sshCommand "ssh -o RepoMarker=1"
deadline 12 "$T/ssh4.out" bash "$AM" maintain
check "core.sshCommand is kept, BatchMode added"         bash -c "grep -q 'RepoMarker=1 -o BatchMode=yes' '$T/ssh.args'"
git -C "$P/b-ssh" config --unset core.sshCommand
git -C "$P/b-ssh" remote set-url origin "$T/p/remotes/b-ssh.git"

# A credential prompt is only allowed with a terminal on stdin, so this runs
# under a real one (a forked pty) - where one-at-a-time maintenance would ask.
if python3 -c 'import pty' 2>/dev/null; then
    cat > "$T/ptyrun.py" <<'PY'
import os, pty, select, sys
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
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
    out += d
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(bytes(out)); sys.stdout.flush()
sys.exit(os.waitstatus_to_exitcode(st))
PY
    git -C "$P/c-ok" remote set-url origin "askcred::https://example.invalid/c.git"
    deadline 12 "$T/cred.out" python3 "$T/ptyrun.py" bash "$AM" maintain; rc=$?
    check "an https remote that would ask for a username: run ends (rc ${rc}, not 124)" [ "$rc" -eq 1 ]
    check "  that repo failed, saying why"               bash -c "grep -q 'FAILED .*c-ok' '$T/cred.out' && grep -q 'terminal prompts disabled' '$T/cred.out'"
    check "  the others were maintained"                 grep -q 'Summary: 2 ok, 0 skipped, 1 failed' "$T/cred.out"
    git -C "$P/c-ok" remote set-url origin "$T/p/remotes/c-ok.git"
else
    echo "   skip - no python pty: the credential prompt is not exercised"
fi
unset ASTROMECH_CONFIG

echo "## 6. a job that crashes fails its repo, not the run"
# date +%F (maintain_repo's stamp) fails once: errexit ends that repo's job
# mid-step, without a result.
cat > "$STUB/date" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == +%F && -n "\${CRASH_ONCE:-}" ]] && mkdir "\$CRASH_ONCE" 2>/dev/null; then exit 1; fi
exec "$REALDATE" "\$@"
STUB
chmod +x "$STUB/date"
K="$T/k/code"; mkdir -p "$K"; for n in k1 k2 k3 k4; do mkrepo "$K/$n"; upstream "$K/$n" "g-$n" up; done
setroot "$K" "$T/k.conf"
CRASH_ONCE="$T/crashed" ASTROMECH_CONFIG="$T/k.conf" bash "$AM" maintain >"$T/crash.out" 2>&1; rc=$?
check "exit 1: a repo failed"                            [ "$rc" -eq 1 ]
check "the summary is still printed: 3 ok, 1 failed"     grep -q 'Summary: 3 ok, 0 skipped, 1 failed' "$T/crash.out"
check "  the crashed repo is named, and why"             grep -q 'FAILED .*k[1-4]: maintenance stopped unexpectedly' "$T/crash.out"
check "the other three were pulled"                      [ "$(ls "$K"/k*/g-k* 2>/dev/null | wc -l | tr -d ' ')" -eq 3 ]
check "the lock is released"                             [ ! -e "$LOCK" ]
rm -f "$STUB/date"

echo "## 7. an interrupt stops the jobs and releases the lock"
I="$T/i/code"; mkdir -p "$I"; for n in i1 i2 i3; do mkrepo "$I/$n"; done
setroot "$I" "$T/i.conf"
# interrupt SIG [launcher...] — starts maintain with every pull hanging, sends
# SIG once all three pulls are under way; sets IRC (exit status, or 124 if
# it outlived the signal) and leaves the report in $T/int.out.
interrupt() {
    local sig="$1" p n=0; shift
    : > "$T/int.log"; rm -f "$T/pids.git"
    ASTROMECH_CONFIG="$T/i.conf" FAKEGIT_LOG="$T/int.log" FAKEGIT_HANG=1 "$@" bash "$AM" maintain >"$T/int.out" 2>&1 & p=$!
    while [ "$(grep -c '^S' "$T/int.log")" -lt 3 ] && (( n < 100 )); do sleep 0.1; n=$((n + 1)); done
    kill -"$sig" "$p"; n=0
    while kill -0 "$p" 2>/dev/null && (( n < 100 )); do sleep 0.1; n=$((n + 1)); done
    if kill -0 "$p" 2>/dev/null; then IRC=124; kill -KILL "$p"; wait "$p" 2>/dev/null; else wait "$p"; IRC=$?; fi
}
# A zombie is dead too: in a container with no init as pid 1 nothing reaps
# the reparented ones, and kill -0 still finds them.
orphans() {
    local q
    for q in $(cat "$T/pids.git" 2>/dev/null); do
        kill -0 "$q" 2>/dev/null || continue
        [[ -r /proc/$q/stat ]] && [[ "$(cut -d' ' -f3 "/proc/$q/stat" 2>/dev/null)" == Z ]] && continue
        return 0
    done
    return 1
}
interrupt TERM
check "TERM: maintain exits 143 (got ${IRC})"            [ "$IRC" -eq 143 ]
check "  the run lock is released"                       [ ! -e "$LOCK" ]
check "  no job or git is left running"                  bash -c "$(declare -f orphans); T='$T'; ! orphans"
check "  and it says which repos were stopped"           grep -q 'interrupted (SIGTERM): 3 repo(s) stopped' "$T/int.out"
check "  no buffers left behind"                         bash -c "[ -z \"\$(ls -A '$TMPDIR')\" ]"
# A background job of this (non-interactive) script starts with SIGINT
# ignored, and bash then cannot trap it; perl restores the default first, as a
# terminal's Ctrl-C would find it.
if command -v perl >/dev/null; then
    interrupt INT perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV'
    check "INT (Ctrl-C): maintain exits 130 (got ${IRC})" [ "$IRC" -eq 130 ]
    check "  the run lock is released"                   [ ! -e "$LOCK" ]
    check "  no job or git is left running"              bash -c "$(declare -f orphans); T='$T'; ! orphans"
else
    echo "   skip - no perl: SIGINT is not exercised"
fi

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
