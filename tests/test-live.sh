#!/usr/bin/env bash
# The live block on a terminal (Kamino item 240): maintain draws one line per
# repo and updates it in place while the jobs run. Run under a real terminal (python's pty), read back
# through a small terminal emulator: what is left on the screen, and every line
# drawn in place, measured.
#
#   - in place: the running lines are redrawn (cursor up, line cleared), and
#     the screen ends with each repo's final line, in order, nothing stale;
#   - never wrapped: on a terminal narrower than a line every line is cut to
#     the width, and a block taller than the terminal is summed up;
#   - interrupted, the block is left saying what became of each repo and the
#     cursor is visible again;
#   - TERM=dumb gets the plain lines.
#
# No network: file:// remotes, a git stub on PATH to slow or hang a pull.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM="${ASTROMECH:-${TEST_DIR}/../astromech.sh}"
[[ -f "$AM" ]] || { echo "astromech.sh not found at $AM" >&2; exit 1; }
if ! python3 -c 'import pty, fcntl, termios' 2>/dev/null; then
    echo "   skip - no python3 pty: the terminal display is not exercised"
    exit 0
fi

T=$(mktemp -d)
T="$(cd "$T" && pwd -P)"
cleanup() {
    local p
    for p in $(cat "$T"/pids 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME="$T/home" TMPDIR="$T/tmp"; mkdir -p "$HOME" "$TMPDIR"
unset XDG_RUNTIME_DIR GIT_SSH GIT_SSH_COMMAND COLUMNS LINES
# A UTF-8 locale where there is one: the symbols and the cut are then by
# character. (Without one the engine falls back to ASCII; the checks hold.)
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qx "$l"; then export LC_ALL="$l"; break; fi
done
probe="→"; E="…"; (( ${#probe} == 1 )) || E="..."   # the engine's ellipsis here
LOCK="$HOME/.local/state/astromech/run.lock"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

# ---- a terminal, and a screen to read it back from ---------------------------
# term.py ROWS COLS [--sig SECS SIG] [--ans TEXT] -- CMD... : runs CMD on a pty
# of that size; sends SIG to it after SECS; types TEXT once "[y/N]" shows.
# Writes the raw transcript to stdout and exits with CMD's status.
cat > "$T/term.py" <<'PY'
import os, pty, select, sys, fcntl, termios, struct, signal, time
a = sys.argv[1:]; rows, cols = int(a[0]), int(a[1]); a = a[2:]
sig_at = sig = ans = None
while a[0] != '--':
    if a[0] == '--sig': sig_at, sig = float(a[1]), getattr(signal, a[2]); a = a[3:]
    elif a[0] == '--ans': ans = a[1]; a = a[2:]
a = a[1:]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    os.execvp(a[0], a)
out = bytearray(); t0 = time.time(); st = None
while True:
    if sig_at is not None and time.time() - t0 >= sig_at:
        os.kill(pid, sig); sig_at = None
    if ans is not None and b'[y/N]' in out:
        os.write(fd, (ans + '\n').encode()); ans = None
    if select.select([fd], [], [], 0.05)[0]:
        try: d = os.read(fd, 65536)
        except OSError: d = b''
        if d: out += d; continue
    p, s = os.waitpid(pid, os.WNOHANG)
    if p:
        st = s
        while select.select([fd], [], [], 0.1)[0]:
            try: d = os.read(fd, 65536)
            except OSError: break
            if not d: break
            out += d
        break
    if time.time() - t0 > 60:
        os.kill(pid, signal.SIGKILL)
sys.stdout.buffer.write(bytes(out)); sys.stdout.flush()
sys.exit(os.waitstatus_to_exitcode(st))
PY
# screen.py COLS < transcript : the screen it leaves (scrollback kept), one
# row per line. Understands what the engine sends: CR, LF, cursor up, erase
# line/below, colours, cursor show/hide; wraps at COLS like a terminal.
# --inplace instead prints every line drawn after an erase-line, uncoloured
# and unwrapped, to measure; --cursor prints "hidden" or "shown" (last state).
cat > "$T/screen.py" <<'PY'
import sys, re
cols = int(sys.argv[1]); mode = sys.argv[2] if len(sys.argv) > 2 else ''
d = sys.stdin.buffer.read().decode('utf-8', 'replace').replace('\r\n', '\n')
if mode == '--cursor':
    m = re.findall(r'\x1b\[\?25([lh])', d); print('hidden' if m and m[-1] == 'l' else 'shown'); sys.exit()
if mode == '--inplace':
    for seg in d.split('\x1b[2K')[1:]:
        print(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', re.split(r'[\r\n]', seg)[0]))
    sys.exit()
L = [[]]; r = c = 0; pend = False; i = 0
while i < len(d):
    ch = d[i]
    if ch == '\x1b':
        m = re.match(r'\x1b\[(\??)([0-9;]*)([A-Za-z])', d[i:])
        if m:
            n, f = m.group(2), m.group(3); i += m.end()
            if f == 'A': r = max(0, r - int(n or 1)); pend = False
            elif f == 'K': L[r] = L[r][:c] if n in ('', '0') else []
            elif f == 'J': L[r] = L[r][:c]; del L[r + 1:]
            continue
        i += 1; continue
    if ch == '\r': c = 0; pend = False
    elif ch == '\n':
        r += 1; c = 0; pend = False
        while len(L) <= r: L.append([])
    else:
        if pend:
            r += 1; c = 0; pend = False
            while len(L) <= r: L.append([])
        row = L[r]
        while len(row) < c: row.append(' ')
        if c < len(row): row[c] = ch
        else: row.append(ch)
        c += 1
        if c >= cols: c = cols - 1; pend = True
    i += 1
for row in L: print(''.join(row).rstrip())
PY
# tty ROWS COLS [term.py options] -- ARGS... : the engine on a terminal; the
# transcript in $T/raw, the screen it leaves in $T/screen; TRC = exit status.
tty() {
    local rows="$1" cols="$2"; shift 2
    TERM="${TTERM:-xterm}" python3 "$T/term.py" "$rows" "$cols" "$@" > "$T/raw"; TRC=$?
    python3 "$T/screen.py" "$cols" < "$T/raw" > "$T/screen"
}
raw_has()    { grep -qF -- "$1" "$T/raw"; }
screen_has() { grep -qE -- "$1" "$T/screen"; }
# repo_rows : the repo lines on the screen, as "name state" in screen order.
repo_rows()  { sed -nE 's/^  . ([a-z0-9-]+) +([a-zA-Z ]+)(:.*)?$/\1 \2/p' "$T/screen"; }

# ---- fixtures ----------------------------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB"; REALGIT="$(command -v git)"
# git: a pull waits $PULL_DELAY seconds first; with $PULL_HANG it never ends.
cat > "$STUB/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == pull ]]; then
        if [[ -n "\${PULL_HANG:-}" ]]; then echo "\$\$" >> "$T/pids"; exec sleep 60; fi
        sleep "\${PULL_DELAY:-0}"; break
    fi
done
exec "$REALGIT" "\$@"
STUB
chmod +x "$STUB/git"; export PATH="$STUB:$PATH"

R="$T/code"; mkdir -p "$R"
mk() {
    local c="$R/$1"
    git init -q --bare -b main "$T/remotes/$1.git"
    git clone -q "$T/remotes/$1.git" "$c" 2>/dev/null
    git -C "$c" symbolic-ref HEAD refs/heads/main
    echo base > "$c/f"; git -C "$c" add f; git -C "$c" commit -qm base
    git -C "$c" push -q -u origin main; git -C "$c" remote set-head origin main
}
for n in alpha bravo charlie delta echo-with-a-rather-long-name foxtrot; do mk "$n"; done
git -C "$R/charlie" checkout -q --detach
git -C "$R/delta" branch old origin/main
printf 'onboarded=1\nroot=%s\n' "$R" > "$T/c.conf"
export ASTROMECH_CONFIG="$T/c.conf"

echo "## 1. maintain: one line per repo, updated in place"
PULL_DELAY=1 tty 30 120 -- bash "$AM" maintain --tidy --yes --jobs 3
check "exit 0"                                             [ "$TRC" -eq 0 ]
check "a repo was shown pulling while it pulled"           raw_has "pulling${E}"
check "  and the ones waiting as queued"                   raw_has "queued"
check "the block was redrawn in place (cursor up)"         grep -qE $'\033\\[[0-9]+A' "$T/raw"
check "the screen ends with each repo's line, in order"    [ "$(repo_rows | tr '\n' '|')" = "alpha ok|bravo ok|charlie skipped|delta ok|echo-with-a-rather-long-name ok|foxtrot ok|" ]
check "  saying what happened"                             screen_has "^  . delta +ok: pulled, 1 branch deleted$"
check "  and nothing left over from the redraws"           bash -c "! grep -qE 'queued|pulling|checking' '$T/screen'"
check "one line each: no heading lines"                    bash -c "! grep -q '── ' '$T/screen'"
check "the cursor was hidden while drawing"                raw_has $'\033[?25l'
check "  and is shown again"                               [ "$(python3 "$T/screen.py" 120 --cursor < "$T/raw")" = shown ]
check "the summary follows, as before"                     screen_has "^\[info\]  Summary: 5 ok, 1 skipped, 0 failed\.$"
check "the run lock is released"                           [ ! -e "$LOCK" ]

echo "## 2. --jobs 1: the repo's line rewritten as its steps go"
PULL_DELAY=0 tty 30 120 -- bash "$AM" maintain --jobs 1
check "exit 0"                                             [ "$TRC" -eq 0 ]
check "the line said pulling, then was rewritten"          bash -c "grep -qF 'pulling${E}' '$T/raw' && grep -qF \$'\\r\\033[2K' '$T/raw'"
check "the same lines, in order"                           [ "$(repo_rows | tr '\n' '|')" = "alpha ok|bravo ok|charlie skipped|delta ok|echo-with-a-rather-long-name ok|foxtrot ok|" ]
check "  nothing left over"                                bash -c "! grep -qE 'pulling|checking' '$T/screen'"
check "no cursor hiding with one job"                      bash -c "! grep -qF \$'\\033[?25l' '$T/raw'"

echo "## 3. a terminal narrower and shorter than the block"
PULL_DELAY=1 tty 6 34 -- bash "$AM" maintain --jobs 2
check "exit 0"                                             [ "$TRC" -eq 0 ]
python3 "$T/screen.py" 34 --inplace < "$T/raw" > "$T/inplace"
# Measured in characters (awk would count bytes in some locales).
widest() { python3 -c 'import sys; print(max([len(l.rstrip("\n")) for l in open(sys.argv[1], encoding="utf-8")] + [0]))' "$1"; }
check "every line drawn in place fits in 33 columns ($(widest "$T/inplace"))" bash -c "[ -s '$T/inplace' ] && [ $(widest "$T/inplace") -le 33 ]"
check "  cut, with an ellipsis"                            grep -qF "${E}" "$T/inplace"
check "a block taller than the terminal is summed up"      grep -qE "[.…]+ [0-9]+ more" "$T/inplace"
grep -E '^  . [a-z]' "$T/screen" > "$T/final"
check "the final lines are cut, not wrapped ($(widest "$T/final"))" bash -c "[ \"\$(wc -l < '$T/final')\" -eq 6 ] && [ $(widest "$T/final") -le 33 ]"
check "  still in order"                                   [ "$(sed -nE 's/^  . ([a-z]+).*/\1/p' "$T/screen" | tr '\n' ' ')" = "alpha bravo charlie delta echo foxtrot " ]

echo "## 4. interrupted: a readable block, the cursor back"
# Three jobs: alpha, bravo and delta hang in their pulls (charlie, detached,
# is skipped at once and frees its slot); echo and foxtrot never start.
PULL_HANG=1 tty 30 120 --sig 3 SIGTERM -- bash "$AM" maintain --jobs 3
check "TERM: exit 143 (got ${TRC})"                        [ "$TRC" -eq 143 ]
check "the repos being pulled say they were stopped"       [ "$(grep -cE '^  . (alpha|bravo|delta) +stopped: by SIGTERM' "$T/screen")" -eq 3 ]
check "the ones never started say so"                      [ "$(grep -cE '^  . (echo-with-a-rather-long-name|foxtrot) +not started' "$T/screen")" -eq 2 ]
check "  charlie, done before the signal, says what it did" screen_has "^  . charlie +skipped: detached HEAD"
check "  in order"                                         [ "$(repo_rows | cut -d' ' -f1 | tr '\n' ' ')" = "alpha bravo charlie delta echo-with-a-rather-long-name foxtrot " ]
check "nothing is left drawn as running"                   bash -c "! grep -qE 'pulling|queued|checking' '$T/screen'"
check "the cursor is shown again"                          [ "$(python3 "$T/screen.py" 120 --cursor < "$T/raw")" = shown ]
check "the interruption is reported"                       screen_has "interrupted \(SIGTERM\): 3 repo\(s\) stopped"
check "the run lock is released"                           [ ! -e "$LOCK" ]
for p in $(cat "$T/pids" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done; : > "$T/pids"

echo "## 5. TERM=dumb: plain lines, nothing drawn in place"
TTERM=dumb PULL_DELAY=0 tty 30 120 -- bash "$AM" maintain --jobs 3
check "exit 0"                                             [ "$TRC" -eq 0 ]
check "no cursor movement or line erasing"                 bash -c "! grep -qE \$'\\033\\\\[([0-9]+A|2K|J|\\\\?25)' '$T/raw'"
check "the lines are the plain ones"                       screen_has "^delta +ok: pulled$"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
