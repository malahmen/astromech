#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# astromech.sh — routine maintenance for every git repo under a set of folders
# (gum-free, flag-driven CLI engine).
#
# You give it one or more "root" folders that hold git repositories, and the
# top-level folders under them to leave alone. `maintain` then walks every repo
# it finds below the roots (recursively; it never descends into a repo it has
# already found) and brings each one back to an up-to-date default branch:
#
#   - on a feature branch: commit everything (git add -A, auto message),
#     check out main/master
#   - on main/master with local changes: stash them (untracked included) and
#     leave the stash for you
#   - then: git pull --rebase
#
# Nothing is pushed. A failed step is reported and the repo is left exactly as
# that step left it — a stopped rebase stays stopped for whoever ran
# maintenance to resolve — and the run moves on to the next repo. Repos that
# are mid-rebase/merge, on a detached HEAD, or have neither main nor master are
# skipped and reported, never touched.
#
# `tidy` is the other half: it deletes local branches whose work the trunk
# already holds. Git has no configuration that does this — fetch.prune only
# touches remote-tracking refs, and a forge's "delete branch on merge" only the
# branch on the forge — so it is a command, and because it deletes refs it
# shows the full list first and then asks.
#
# `prune` is the setting next door, and the one people confuse with tidy:
# fetch.prune drops stale origin/* REMOTE-TRACKING refs on fetch, while nothing
# in git deletes merged LOCAL branches. It shows the state and the reason, and
# toggles the global value.
#
# Prompt-free by default: everything is driven by commands and flags, so it
# drops into a cron job, a systemd timer or a TUI alike. tidy is the single
# exception, and only because it deletes — an unattended run passes --yes to
# say so out loud, or --dry-run to only list. The interactive experience lives
# in a separate front-end (scomp-link) that drives this engine with flags —
# the holo-convert / holonet-sync pattern.
#
# Requirements: bash >= 4, git >= 2.13. Run --help for the command list.
#
# Config: ~/.config/astromech/astromech.conf   (one key=value per line)
# -----------------------------------------------------------------------------

# Arrays-of-paths handling and mapfile are load-bearing here; macOS's system
# bash 3.2 would fail later, mid-run, with far less obvious errors.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

set -euo pipefail
shopt -s nullglob

SCRIPT_NAME="astromech"
VERSION="1.1.0"

# ---- gum-free status output (stderr; stdout stays clean for data) ------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Unattended runs (cron, a systemd timer) get a leading UTC timestamp, since a
# mail spool or a log file has no other clock; a terminal already has one, and
# gets colour instead.
if [[ -t 2 ]]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_B=$'\033[1m'; C_N=$'\033[0m'
    _pfx() { printf ''; }
else
    C_G=""; C_Y=""; C_R=""; C_C=""; C_B=""; C_N=""
    _pfx() { printf '%s ' "$(_ts)"; }
fi

info()       { printf '%s%s[info]%s  %s\n'  "$(_pfx)" "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s%s[ok]%s    %s\n'  "$(_pfx)" "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s%s[warn]%s  %s\n'  "$(_pfx)" "$C_Y" "$C_N" "$*" >&2; }
error()      { printf '%s%s[error]%s %s\n'  "$(_pfx)" "$C_R" "$C_N" "$*" >&2; }
error_exit() { error "$*"; exit 1; }
dbg()        { if (( VERBOSE )); then printf '%s[debug] %s\n' "$(_pfx)" "$*" >&2; fi; }

command -v git &>/dev/null || error_exit "git is required."

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

CONFIG_FILE="${ASTROMECH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/astromech/astromech.conf}"
# How deep below a root to look for repos. Repos are never descended into, so
# this only bounds the walk through plain (non-repo) folders.
MAX_DEPTH="${ASTROMECH_MAX_DEPTH:-6}"

# No terminal (cron): a git credential prompt would hang the run forever.
[[ -t 0 ]] || export GIT_TERMINAL_PROMPT=0

# ---- runtime flags ----------------------------------------------------------
DRY_RUN=0
VERBOSE=0
ONLY_REPO=""
TIDY=0
ASSUME_YES=0

# ---- config (filled by load_config) -----------------------------------------
ROOTS=()
IGNORES=()
ONBOARDED=0

usage() {
    cat >&2 <<EOF
${SCRIPT_NAME} ${VERSION} — keep every git repo under your folders on a fresh main/master

USAGE
  ${SCRIPT_NAME}.sh <command> [args] [flags]

COMMANDS
  maintain                 run maintenance on every repo (or one, with --repo)
  tidy                     list local branches already merged into the trunk, then delete them
  prune [on|off]           show or toggle git's fetch.prune (stale origin/* refs), with why
  status                   tree per root: repos (branch, dirty) and ignored folders (stdout)
  roots                    print the configured roots, one per line (stdout)
  add-root PATH...         add folder(s) holding git repos; prints each added (absolute) path (stdout)
  remove-root PATH...      remove root(s) and every ignore beneath them
  children ROOT            print ROOT's top-level folders as TSV: name<TAB>ignored(0|1) (stdout)
  ignores                  print the ignored folders (absolute), one per line (stdout)
  set-ignores ROOT [NAME...]
                           replace ROOT's ignored top-level folders with NAME... (none = clear)
  repos                    print discovered repos as TSV: root<TAB>repo (stdout)
  config                   print the resolved config as key=value (stdout)
  mark-onboarded           record that the first-run prompt has been answered
  version                  print version

FLAGS
  --config PATH            config file (default: ${CONFIG_FILE/#$HOME/\~})
  --repo PATH              maintain, tidy: limit to one discovered repo
  --dry-run                maintain, tidy: report what would happen, change nothing
  --tidy                   maintain: also tidy each repo once its pull has succeeded
  --dry-run                prune: report the change, write nothing
  -y, --yes                tidy: delete without asking (required when there is no terminal)
  -v, --verbose            debug logging
  -h, --help

Per repo, maintain does:
  feature branch  -> git add -A; git commit (auto message); git checkout main|master
  main|master     -> if dirty: git stash push -u (the stash is left for you)
  then            -> git pull --rebase
Nothing is pushed. A failed step leaves the repo as that step left it (a stopped
rebase stays stopped for you to resolve) and the run moves on. Repos mid-rebase/
merge, on a detached HEAD, or with neither main nor master are skipped.

prune is the adjacent git setting, and the distinction people trip over:
fetch.prune drops stale origin/* REMOTE-TRACKING refs on every fetch, and
nothing at all configures the deletion of merged LOCAL branches — that is tidy.
'prune' alone shows the current state, what it does and does not prune, and any
repository that overrides it locally; 'prune on|off' writes the global setting
and prints the way back.

tidy prints every local branch already contained in its trunk (as of the last
fetch) with the repo and the short sha, then asks before deleting any of them.
Deletion is git branch -d, never -D, so git has to agree too. "Merged" is
measured against origin/<trunk>, not the local one: a local trunk can be behind
or hold commits that were never pushed. --dry-run lists and stops; --yes skips
the question, which an unattended run must pass explicitly.
Exit status: 0 when no repo failed, 1 otherwise. Logs go to stderr.
EOF
}

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------

load_config() {
    ROOTS=(); IGNORES=(); ONBOARDED=0
    [[ -f "$CONFIG_FILE" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" != *=* ]]; then warn "config: ignoring malformed line: ${line}"; continue; fi
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            root)      ROOTS+=("$val") ;;
            ignore)    IGNORES+=("$val") ;;
            onboarded) ONBOARDED="$val" ;;
            *)         warn "config: unknown key '${key}'" ;;
        esac
    done < "$CONFIG_FILE"
}

# Written atomically: a crash mid-write must never leave a half config behind.
save_config() {
    local dir tmp r i
    dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$dir"
    tmp="$(mktemp "${dir}/.astromech.conf.XXXXXX")"
    {
        echo "# astromech config — managed by astromech.sh; one key=value per line."
        echo "# root=<folder holding git repos>    ignore=<root>/<top-level folder to skip>"
        echo "onboarded=${ONBOARDED}"
        for r in "${ROOTS[@]}";   do echo "root=${r}"; done
        for i in "${IGNORES[@]}"; do echo "ignore=${i}"; done
    } > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# _abspath PATH — echoes the absolute, ~-expanded path of an existing directory.
_abspath() {
    local p="${1/#\~/$HOME}"
    [[ -d "$p" ]] || return 1
    (cd "$p" && pwd)
}

# _canon PATH — the path with symlinks resolved, or PATH itself if it cannot be
# entered. Needed only for COMPARING paths, never for storing them: on an
# ostree host (Fedora Atomic, bazzite) /home is a symlink to /var/home, so a
# root added as ~/code and a path tab-completed in a shell sitting at
# /var/home/... are two spellings of one directory. Compared literally, --repo
# reports "not a discovered repo" about the very directory you are standing in.
_canon() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

_has_root() {
    local r
    for r in "${ROOTS[@]}"; do [[ "$r" == "$1" ]] && return 0; done
    return 1
}

# _resolve_root PATH — echoes the configured root PATH refers to (exact string
# first, so a root whose folder was deleted can still be named and removed).
_resolve_root() {
    local want="${1/#\~/$HOME}" abs
    want="${want%/}"
    _has_root "$want" && { printf '%s' "$want"; return 0; }
    abs="$(_abspath "$want")" || return 1
    _has_root "$abs" && { printf '%s' "$abs"; return 0; }
    return 1
}

_is_ignored() {
    local i
    for i in "${IGNORES[@]}"; do [[ "$i" == "$1" ]] && return 0; done
    return 1
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

# _walk DIR DEPTH — prints every repo at or below DIR, without descending into
# a repo once found. Skips hidden folders, symlinks (no loops) and ignores.
_walk() {
    local dir="$1" depth="$2" child
    if [[ -e "${dir}/.git" ]]; then printf '%s\n' "$dir"; return 0; fi
    (( depth >= MAX_DEPTH )) && return 0
    for child in "$dir"/*/; do
        child="${child%/}"
        [[ -L "$child" ]] && continue
        _is_ignored "$child" && { dbg "ignored: ${child}"; continue; }
        _walk "$child" $(( depth + 1 ))
    done
}

# Fills REPO_LIST / REPO_ROOT (parallel arrays), deduplicated across roots.
REPO_LIST=(); REPO_ROOT=()
discover() {
    REPO_LIST=(); REPO_ROOT=()
    local -A seen=()
    local root repo
    for root in "${ROOTS[@]}"; do
        if [[ ! -d "$root" ]]; then warn "root not found (skipped): ${root}"; continue; fi
        while IFS= read -r repo; do
            [[ -n "${seen[$repo]:-}" ]] && continue
            seen[$repo]=1
            REPO_LIST+=("$repo"); REPO_ROOT+=("$root")
        done < <(_walk "$root" 0)
    done
}

# -----------------------------------------------------------------------------
# Git helpers
# -----------------------------------------------------------------------------

# _git REPO ARGS... — runs git quietly; on failure, shows git's own output
# (indented) so the report says *why*, not just *that*.
_git() {
    local repo="$1"; shift
    local out rc=0
    dbg "git -C ${repo} $*"
    out="$(git -C "$repo" "$@" 2>&1)" || rc=$?
    if (( rc )) || (( VERBOSE )); then
        [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/          /' >&2
    fi
    return "$rc"
}

_is_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

_current_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }

# main if it exists locally or on origin, else master; nothing → return 1.
# _default_branch <repo> — the branch this repository considers its trunk.
#
# Order matters, and the old order was wrong. It tried 'main' then 'master',
# accepting either a local OR a remote ref, so a repository mid-rename — a
# local 'master', with 'main' existing only on origin — was told its default
# was 'main'. 'master' was then treated as a FEATURE branch: a dirty tree got
# wip-committed onto it and the run switched away to 'main', and the next push
# published that wip commit.
#
#   1. origin/HEAD, when it names a branch that exists. It is the remote's own
#      answer and the only one that stays right through a rename.
#   2. The branch currently checked out, if it is main or master. Whatever
#      else is true, the trunk you are standing on is not a feature branch.
#   3. A local main or master.
#   4. A remote-only main or master, for a repository not yet checked out on
#      either — the old behaviour, now last instead of first.
_default_branch() {
    local repo="$1" b head

    head="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    head="${head#origin/}"
    if [[ -n "$head" ]]; then
        # Validated, not trusted: origin/HEAD can be a stale symref left
        # pointing at a branch that has since been deleted, and naming a
        # branch that does not exist would fail the checkout later instead of
        # here.
        if git -C "$repo" show-ref --verify -q "refs/heads/${head}" \
            || git -C "$repo" show-ref --verify -q "refs/remotes/origin/${head}"; then
            printf '%s' "$head"; return 0
        fi
    fi

    b="$(_current_branch "$repo" || true)"
    case "$b" in
        main|master) printf '%s' "$b"; return 0 ;;
    esac

    for b in main master; do
        if git -C "$repo" show-ref --verify -q "refs/heads/${b}"; then
            printf '%s' "$b"; return 0
        fi
    done
    for b in main master; do
        if git -C "$repo" show-ref --verify -q "refs/remotes/origin/${b}"; then
            printf '%s' "$b"; return 0
        fi
    done
    return 1
}

# Echoes the name of an operation in progress (rebase, merge, …), or nothing.
_in_progress() {
    local gd
    gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "unreadable git dir"; return; }
    if   [[ -d "${gd}/rebase-merge" || -d "${gd}/rebase-apply" ]]; then echo "rebase"
    elif [[ -f "${gd}/MERGE_HEAD" ]];       then echo "merge"
    elif [[ -f "${gd}/CHERRY_PICK_HEAD" ]]; then echo "cherry-pick"
    elif [[ -f "${gd}/REVERT_HEAD" ]];      then echo "revert"
    elif [[ -f "${gd}/BISECT_LOG" ]];       then echo "bisect"
    fi
}

# -----------------------------------------------------------------------------
# maintain
# -----------------------------------------------------------------------------

# Result of the last maintain_repo: R_STATUS = ok|skipped|failed, R_NOTE = why.
R_STATUS=""; R_NOTE=""
_ok()   { R_STATUS=ok;      R_NOTE="$1"; success "$1"; }
_skip() { R_STATUS=skipped; R_NOTE="$1"; warn "skipped: $1"; }
_fail() { R_STATUS=failed;  R_NOTE="$1"; error "$1"; }

maintain_repo() {
    local repo="$1" op branch def notes=() stamp
    stamp="$(date +%F)"

    if [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]]; then
        _skip "not a git work tree"; return
    fi
    op="$(_in_progress "$repo")"
    [[ -n "$op" ]] && { _skip "${op} in progress — finish or abort it first"; return; }
    branch="$(_current_branch "$repo")" || { _skip "detached HEAD"; return; }
    def="$(_default_branch "$repo")"    || { _skip "no main or master branch"; return; }

    if [[ "$branch" != "$def" ]]; then
        if _is_dirty "$repo"; then
            if (( DRY_RUN )); then
                info "would commit all changes on '${branch}'"
            else
                # '|| true' on the recovery, like the commit branch below.
                # Without it this was fatal to the WHOLE RUN: errexit applies
                # inside the { } group, 'add -A' fails on a stale index.lock,
                # and the 'reset' recovering from it fails for exactly the same
                # reason — so the script exited 128 right there, printing no
                # summary and skipping every remaining repository. Under cron
                # one interrupted git stopped maintenance of everything.
                _git "$repo" add -A || {
                    _git "$repo" reset -q || true
                    _fail "git add -A failed on '${branch}' (a stale .git/index.lock?)"
                    return
                }
                if ! _git "$repo" commit -q -m "wip: auto-commit before astromech maintenance (${stamp})"; then
                    _git "$repo" reset -q || true   # unstage again; the working tree is untouched
                    _fail "commit on '${branch}' failed (hook? identity?) — nothing changed"; return
                fi
                info "committed changes on '${branch}'"
            fi
            notes+=("committed '${branch}'")
        fi
        if (( DRY_RUN )); then
            info "would check out '${def}'"
        else
            _git "$repo" checkout -q "$def" || { _fail "checkout '${def}' failed (still on '${branch}')"; return; }
            info "checked out '${def}' (was '${branch}')"
        fi
        notes+=("${branch} → ${def}")
    elif _is_dirty "$repo"; then
        if (( DRY_RUN )); then
            info "would stash local changes on '${def}'"
        else
            _git "$repo" stash push -q -u -m "astromech: before pull (${stamp})" \
                || { _fail "stash on '${def}' failed — nothing changed"; return; }
            info "stashed local changes on '${def}' (left in the stash: git stash list)"
        fi
        notes+=("stashed")
    fi

    if (( DRY_RUN )); then
        info "would git pull --rebase on '${def}'"
        notes+=("pull")
        _ok "dry run: ${notes[*]}"; return
    fi

    if ! _git "$repo" pull -q --rebase; then
        if [[ "$(_in_progress "$repo")" == rebase ]]; then
            _fail "pull --rebase stopped on a conflict — left mid-rebase for you (git status; rebase --continue/--abort)"
        else
            _fail "pull --rebase failed on '${def}' (no upstream? offline?)"
        fi
        return
    fi
    notes+=("pulled")
    local joined; joined="$(IFS=,; echo "${notes[*]}")"
    _ok "${joined//,/, }"
}

# A run lock, so a cron run and a manual one cannot interleave. Two astromech
# processes in the same repository is one way an index.lock becomes "stale" in
# the first place: one of them is holding it legitimately while the other
# reports it as wreckage.
#
# A directory, not flock(1): mkdir is atomic everywhere and macOS ships no
# flock. Under XDG_RUNTIME_DIR when there is one (per-user, tmpfs, cleared on
# logout), else TMPDIR — which may be shared, hence the uid in the name.
_LOCK_DIR=""
_lock_path() { printf '%s/astromech-%s.lock' "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" "$(id -u)"; }

_run_lock() {
    local d; d="$(_lock_path)"
    if mkdir "$d" 2>/dev/null; then
        printf '%s\n' "$$" > "${d}/pid"; _LOCK_DIR="$d"; return 0
    fi
    # Held — or abandoned. A holder that no longer exists must not block
    # maintenance forever: that turns one killed run into a silent stop.
    local pid; pid="$(cat "${d}/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    warn "removing a stale run lock (${d}; pid ${pid:-unknown} is gone)"
    rm -rf "$d"
    mkdir "$d" 2>/dev/null || return 1
    printf '%s\n' "$$" > "${d}/pid"; _LOCK_DIR="$d"
}

_release_lock() { [[ -n "$_LOCK_DIR" ]] && rm -rf "$_LOCK_DIR"; _LOCK_DIR=""; }

# Fills TARGETS with indices into REPO_LIST: every discovered repo, or only the
# one named by --repo. Shared by maintain and tidy so that --repo means the
# same thing, and fails the same way, in both.
TARGETS=()
_select_targets() {
    TARGETS=()
    local i want
    if [[ -n "$ONLY_REPO" ]]; then
        want="$(_abspath "$ONLY_REPO")" || error_exit "--repo: not a directory: ${ONLY_REPO}"
        local cwant; cwant="$(_canon "$want")"
        for i in "${!REPO_LIST[@]}"; do
            [[ "${REPO_LIST[$i]}" == "$want" || "$(_canon "${REPO_LIST[$i]}")" == "$cwant" ]] \
                && TARGETS+=("$i")
        done
        (( ${#TARGETS[@]} )) || error_exit "--repo: ${want} is not a discovered repo (see: ${SCRIPT_NAME}.sh repos)"
    else
        TARGETS=("${!REPO_LIST[@]}")
    fi
}

cmd_maintain() {
    # Taken before discovery so two runs cannot both walk the roots and then
    # both start writing.
    _run_lock || error_exit "another ${SCRIPT_NAME} maintenance run is in progress (lock: $(_lock_path)). Wait for it, or remove the lock if you are sure it is dead."
    trap '_release_lock' EXIT
    load_config
    (( ${#ROOTS[@]} )) || error_exit "No roots configured. Add one: ${SCRIPT_NAME}.sh add-root PATH"
    discover

    local i
    _select_targets
    local targets=("${TARGETS[@]}")
    (( ${#targets[@]} )) || { warn "No repositories found under the configured roots."; return 0; }

    (( DRY_RUN )) && info "Dry run — nothing will be changed."
    # Asked once, before the first repo is touched, and not per repo: which
    # branches become deletable is only known after each pull, so there is no
    # list to show up front. 'tidy --dry-run' is where the list lives.
    if (( TIDY )) && ! (( DRY_RUN )); then
        _tidy_confirm "Also delete local branches already merged into the trunk, in each repo, after its pull?" \
            || error_exit "declined — nothing was changed. Run '${SCRIPT_NAME}.sh tidy --dry-run' to see what tidy would delete."
    fi
    info "Maintaining ${#targets[@]} repo(s)…"

    local n_ok=0 n_skip=0 n_fail=0 rel lines=()
    for i in "${targets[@]}"; do
        rel="${REPO_LIST[$i]#"${REPO_ROOT[$i]}"/}"
        [[ "${REPO_LIST[$i]}" == "${REPO_ROOT[$i]}" ]] && rel="."
        printf '\n%s%s── %s%s  %s\n' "$(_pfx)" "$C_B" "$rel" "$C_N" "(${REPO_ROOT[$i]/#$HOME/\~})" >&2
        maintain_repo "${REPO_LIST[$i]}"
        case "$R_STATUS" in
            ok)      n_ok=$((n_ok + 1))
                     # Only after a repo came back clean and up to date: the
                     # pull is what makes origin/<trunk> current, and tidying
                     # against a stale one would spare branches it already
                     # holds. A repo that was skipped or failed keeps all of
                     # its branches.
                     if (( TIDY )); then
                         TIDY_PLAN=(); TIDY_NOTES=()
                         _tidy_plan_repo "${REPO_LIST[$i]}"
                         if (( DRY_RUN )); then _tidy_print_plan
                         else _tidy_apply; fi
                     fi
                     ;;
            skipped) n_skip=$((n_skip + 1));  lines+=("skipped  ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
            failed)  n_fail=$((n_fail + 1));  lines+=("FAILED   ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
        esac
    done

    printf '\n' >&2
    info "Summary: ${n_ok} ok, ${n_skip} skipped, ${n_fail} failed."
    if (( TIDY )); then info "Tidy: ${TIDY_DELETED} branch(es) deleted, ${TIDY_FAILED} refused."; fi
    local l
    for l in "${lines[@]}" "${TIDY_LINES[@]}"; do printf '          %s\n' "$l" >&2; done
    (( n_fail == 0 && TIDY_FAILED == 0 ))
}

# -----------------------------------------------------------------------------
# tidy — delete local branches whose work the trunk already holds
# -----------------------------------------------------------------------------
#
# Git has no setting for this, and that is deliberate: a local branch is your
# own bookmark and git will not collect your bookmarks. (fetch.prune only ever
# touches remote-tracking refs, and a forge's "delete branch on merge" only the
# branch on the forge. Neither is this.) So it is a command — but a command
# that deletes refs has to say what it is about to delete and be told to go
# ahead, which is what the plan/confirm split below is for.
#
# Two things make it safe rather than merely careful:
#
#   - "merged" is measured against the trunk ON ORIGIN, not the local one. The
#     local trunk can be behind, or carry commits that were never pushed; "the
#     work is on the remote" is the only reading of merged under which losing
#     the local ref loses nothing.
#   - deletion is `git branch -d`, never -D. The plan is this script's opinion;
#     -d is git's own, and a branch has to satisfy both.

TIDY_PLAN=()        # "<repo>\t<branch>\t<base>", in discovery order
TIDY_NOTES=()       # repos that could not be planned, and why
TIDY_DELETED=0; TIDY_FAILED=0; TIDY_LINES=()

# _tidy_plan_repo <repo> — appends one TIDY_PLAN entry per local branch of
# <repo> that is already contained in its trunk. Reads only.
_tidy_plan_repo() {
    local repo="$1" op trunk base b wt n=0

    if [[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]]; then
        TIDY_NOTES+=("${repo}: not a git work tree"); return 0
    fi
    op="$(_in_progress "$repo")"
    [[ -n "$op" ]] && { TIDY_NOTES+=("${repo}: ${op} in progress — left alone"); return 0; }
    trunk="$(_default_branch "$repo")" || { TIDY_NOTES+=("${repo}: no main or master branch"); return 0; }

    if git -C "$repo" show-ref --verify -q "refs/remotes/origin/${trunk}"; then
        base="origin/${trunk}"
    elif git -C "$repo" show-ref --verify -q "refs/heads/${trunk}"; then
        # No remote at all (or never fetched): the local trunk is the only
        # answer there is. Said out loud, because it is the weaker one.
        base="$trunk"
        TIDY_NOTES+=("${repo}: no origin/${trunk} — measured against the local ${trunk} instead")
    else
        TIDY_NOTES+=("${repo}: '${trunk}' exists neither locally nor on origin"); return 0
    fi

    while IFS=$'\t' read -r b wt; do
        [[ -n "$b" ]] || continue
        [[ "$b" == "$trunk" ]] && continue
        # A branch checked out anywhere — here or in another worktree — has a
        # worktreepath, and git refuses to delete it. It must not appear in a
        # list that says it will be deleted.
        [[ -n "$wt" ]] && continue
        git -C "$repo" merge-base --is-ancestor "refs/heads/${b}" "$base" 2>/dev/null || continue
        TIDY_PLAN+=("${repo}"$'\t'"${b}"$'\t'"${base}")
        n=$(( n + 1 ))
    done < <(git -C "$repo" for-each-ref --format=$'%(refname:short)\t%(worktreepath)' refs/heads/ 2>/dev/null)
    dbg "${repo}: ${n} branch(es) contained in ${base}"
}

# The prediction list. On stdout, like status and repos, so it can be saved,
# diffed or reviewed before anything happens; commentary stays on stderr.
# The short sha is the recovery handle: git branch <name> <sha> brings a branch
# back, and nothing else printed here identifies the commit.
_tidy_print_plan() {
    local p repo b base cur="" sha repos=0
    if (( ${#TIDY_PLAN[@]} )); then
        printf 'branches already contained in their trunk — these would be deleted:\n\n'
        for p in "${TIDY_PLAN[@]}"; do
            IFS=$'\t' read -r repo b base <<< "$p"
            if [[ "$repo" != "$cur" ]]; then
                (( repos )) && printf '\n'
                cur="$repo"; repos=$(( repos + 1 ))
                printf '  %s  (merged into %s)\n' "${repo/#$HOME/\~}" "$base"
            fi
            sha="$(git -C "$repo" rev-parse --short "refs/heads/${b}" 2>/dev/null || echo '?')"
            printf '      %-44s %s\n' "$b" "$sha"
        done
        printf '\n  %d branch(es) in %d repo(s).\n\n' "${#TIDY_PLAN[@]}" "$repos"
    fi
    if (( ${#TIDY_NOTES[@]} )); then
        local note
        for note in "${TIDY_NOTES[@]}"; do warn "${note/#$HOME/\~}"; done
    fi
}

# _tidy_confirm <question> — 0 go ahead, 1 could not ask, 2 declined.
#
# Those last two must not share a status. Declining is a choice and the run
# ends fine; being unable to ask is a request that did not happen, and a cron
# job or a front-end has to hear about it rather than read a clean exit as "no
# branches needed deleting".
#
# A run with no terminal (cron, a systemd timer, scomp-link driving the engine)
# cannot be asked, so it has to carry --yes: silence is not consent. Note this
# OPENS /dev/tty rather than testing it — a process with no controlling
# terminal still has a /dev/tty that passes -r and -c, and the read then fails
# on a question nobody was shown.
_tidy_confirm() {
    local q="$1" ans=""
    (( ASSUME_YES )) && return 0
    ( : <>/dev/tty ) 2>/dev/null || {
        error "no terminal to confirm on, and --yes was not given."
        error "Re-run with --yes to delete without asking, or --dry-run to only list."
        return 1
    }
    printf '%s [y/N] ' "$q" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) info "Declined — nothing deleted."; return 2 ;;
    esac
}

# _tidy_apply — deletes everything in TIDY_PLAN, one branch at a time.
_tidy_apply() {
    local p repo b base sha
    for p in "${TIDY_PLAN[@]}"; do
        IFS=$'\t' read -r repo b base <<< "$p"
        sha="$(git -C "$repo" rev-parse --short "refs/heads/${b}" 2>/dev/null || echo '?')"
        if _git "$repo" branch -d "$b"; then
            TIDY_DELETED=$(( TIDY_DELETED + 1 ))
            info "deleted ${b} (was ${sha}) in ${repo/#$HOME/\~}"
        else
            # git's -d test is narrower than this plan's: it asks whether the
            # branch is contained in HEAD or in its own upstream, so a local
            # trunk sitting behind origin's can make it refuse a branch that
            # origin's trunk demonstrably holds. Reported, never forced — -D
            # is the operator's call, and the sha above is enough to recover
            # either way.
            TIDY_FAILED=$(( TIDY_FAILED + 1 ))
            TIDY_LINES+=("REFUSED  ${repo/#$HOME/\~}: ${b} (${sha}) — git -C ${repo/#$HOME/\~} branch -D ${b}  # contained in ${base}")
        fi
    done
}

cmd_tidy() {
    _run_lock || error_exit "another ${SCRIPT_NAME} run is in progress (lock: $(_lock_path)). Wait for it, or remove the lock if you are sure it is dead."
    trap '_release_lock' EXIT
    load_config
    (( ${#ROOTS[@]} )) || error_exit "No roots configured. Add one: ${SCRIPT_NAME}.sh add-root PATH"
    discover
    _select_targets
    (( ${#TARGETS[@]} )) || { warn "No repositories found under the configured roots."; return 0; }

    # Nothing is fetched here, on purpose: tidy must not reach the network to
    # decide what to delete. It therefore measures against whatever origin/
    # trunk was last fetched, which can only make it see FEWER branches as
    # merged, never more. 'maintain --tidy' pulls first and so sees all of them.
    TIDY_PLAN=(); TIDY_NOTES=()
    local i
    for i in "${TARGETS[@]}"; do _tidy_plan_repo "${REPO_LIST[$i]}"; done

    _tidy_print_plan
    (( ${#TIDY_PLAN[@]} )) || { info "Nothing to tidy: no local branch is already contained in its trunk."; return 0; }
    if (( DRY_RUN )); then
        info "Dry run — nothing was deleted."
        return 0
    fi
    local gate=0
    _tidy_confirm "Delete ${#TIDY_PLAN[@]} merged branch(es)?" || gate=$?
    case "$gate" in
        0) ;;
        2) return 0 ;;   # declined — nothing was asked of git, nothing failed
        *) return 1 ;;   # could not ask: a deletion was requested and did not happen
    esac
    _tidy_apply
    printf '\n' >&2
    info "Summary: ${TIDY_DELETED} deleted, ${TIDY_FAILED} refused."
    if (( ${#TIDY_LINES[@]} )); then
        local l
        for l in "${TIDY_LINES[@]}"; do printf '          %s\n' "$l" >&2; done
    fi
    (( TIDY_FAILED == 0 ))
}

# -----------------------------------------------------------------------------
# prune — the one git setting adjacent to tidy's job
# -----------------------------------------------------------------------------
#
# tidy deletes local branches. This deletes nothing: fetch.prune makes git drop
# the REMOTE-TRACKING refs (origin/*) of branches that no longer exist on the
# remote, at every fetch — and maintain's `git pull --rebase` is a fetch, so
# with it on, maintenance does the pruning as a side effect.
#
# It lives here because it is the question tidy always raises — "isn't there a
# config for this?" — and the answer has two halves that are constantly
# confused with each other:
#
#   the remote-tracking half   yes: fetch.prune, this toggle
#   the local-branch half      no: nothing configures it, that is tidy
#
# Keeping both in one command is the only way that distinction gets made
# somewhere a person will actually read it.
#
# Deliberately not offered: fetch.pruneTags. It prunes local tags the remote no
# longer has, which is a far bigger promise than dropping a stale branch ref,
# and nothing in astromech needs it.

_prune_global() { git config --global --get fetch.prune 2>/dev/null || true; }
_prune_true()   { case "${1,,}" in true|yes|on|1) return 0 ;; *) return 1 ;; esac; }

# The explanation goes to stderr so the key=value report on stdout stays
# parseable — the same split as every other command here.
_prune_explain() {
    cat >&2 <<EOF
          prunes:    stale origin/* remote-tracking refs, at every fetch. And
                     maintain's 'git pull --rebase' is a fetch, so maintenance
                     does it for you.
          does not:  local branches. No git setting deletes those — that is
                     '${SCRIPT_NAME}.sh tidy'. Nor tags: that is
                     fetch.pruneTags, which this toggle leaves alone.
          why:       with a forge deleting each head branch as its PR lands,
                     every merged branch leaves an origin/* ref behind, and
                     'git branch -a', tab completion and your tooling go on
                     offering branches that are gone.
EOF
}

# _prune_overrides — one 'override=<repo><TAB><key><TAB><value>' line per
# discovered repo that sets pruning locally.
#
# Both keys are checked because both beat the global one: a repo-local
# fetch.prune overrides the global fetch.prune, and remote.<name>.prune
# overrides fetch.prune at any scope. Either can silently defeat this toggle in
# one repo, which is otherwise a thing you work out by wondering why.
_prune_overrides() {
    local i repo v
    for i in "${!REPO_LIST[@]}"; do
        repo="${REPO_LIST[$i]}"
        v="$(git -C "$repo" config --local --get fetch.prune 2>/dev/null || true)"
        [[ -n "$v" ]] && printf 'override=%s\t%s\t%s\n' "$repo" "fetch.prune" "$v"
        v="$(git -C "$repo" config --local --get remote.origin.prune 2>/dev/null || true)"
        [[ -n "$v" ]] && printf 'override=%s\t%s\t%s\n' "$repo" "remote.origin.prune" "$v"
    done
    return 0
}

_prune_scan() {
    (( ${#ROOTS[@]} )) || { info "No roots configured, so no repositories were checked for local overrides."; return 0; }
    discover
    local out n
    out="$(_prune_overrides)"
    [[ -n "$out" ]] || return 0
    printf '%s\n' "$out"
    n="$(wc -l <<<"$out" | tr -d ' ')"
    # Not "above": the override lines go to stdout and this to stderr, so a
    # front-end that captures one and streams the other can show them in
    # either order. The warning has to stand on its own.
    warn "fetch.prune is overridden locally in ${n} place(s); a repo-local value and remote.origin.prune both beat the global setting."
}

cmd_prune() {
    (( $# <= 1 )) || error_exit "prune: expected 'on', 'off', or nothing (to show the current state)."
    load_config
    local want="${1:-}" cur curbool new
    cur="$(_prune_global)"
    curbool="unset"
    if [[ -n "$cur" ]]; then
        if _prune_true "$cur"; then curbool=true; else curbool=false; fi
    fi

    case "$want" in
        ""|show)
            printf 'fetch.prune=%s\n' "${cur:-unset}"
            case "$curbool" in
                true)  success "git prunes stale remote-tracking refs on fetch (fetch.prune=${cur}, global)." ;;
                false) warn "pruning is explicitly OFF (fetch.prune=${cur}, global)." ;;
                *)     info "fetch.prune is unset, and git's own default is off — nothing is pruned." ;;
            esac
            _prune_explain
            _prune_scan
            [[ "$curbool" == true ]] || info "Turn it on with: ${SCRIPT_NAME}.sh prune on"
            ;;
        on|off)
            new=true; [[ "$want" == off ]] && new=false
            if [[ "$curbool" == "$new" ]]; then
                info "fetch.prune is already ${new} (global) — nothing changed."
            elif (( DRY_RUN )); then
                info "would set fetch.prune=${new} (global); it is ${curbool} now."
            else
                git config --global fetch.prune "$new" \
                    || error_exit "could not write fetch.prune to the global git config ($(git config --global --list --show-origin 2>/dev/null | sed -n 1p | cut -f1 || echo 'path unknown'))."
                success "fetch.prune: ${curbool} -> ${new} (global)"
                # The exact way back, including the case where there was no
                # line at all before this.
                if [[ -n "$cur" ]]; then
                    info "Undo with: git config --global fetch.prune ${cur}"
                else
                    info "Undo with: git config --global --unset fetch.prune"
                fi
                # No explanation here. 'prune' with no argument is the command
                # that teaches; someone typing 'prune on' has already decided,
                # and twelve lines of why is noise they did not ask for — and
                # a duplicate when a front-end showed the state first.
            fi
            # Read back rather than echo the intent: what is reported is what
            # the config now says, which in a dry run is the unchanged value.
            printf 'fetch.prune=%s\n' "$(_prune_global || true)"
            _prune_scan
            ;;
        *)  error_exit "prune: expected 'on', 'off', or nothing (to show the current state); got '${want}'." ;;
    esac
}

# -----------------------------------------------------------------------------
# Config commands
# -----------------------------------------------------------------------------

cmd_add_root() {
    (( $# )) || error_exit "add-root: give at least one PATH."
    load_config
    local p abs added=0
    for p in "$@"; do
        abs="$(_abspath "$p")" || error_exit "add-root: not a directory: ${p}"
        if _has_root "$abs"; then warn "already a root: ${abs}"; continue; fi
        ROOTS+=("$abs"); added=$((added + 1))
        success "root added: ${abs}"
        printf '%s\n' "$abs"
    done
    (( added )) && save_config
    return 0
}

cmd_remove_root() {
    (( $# )) || error_exit "remove-root: give at least one PATH."
    load_config
    local p root r i keep_r=() keep_i=()
    for p in "$@"; do
        root="$(_resolve_root "$p")" || error_exit "remove-root: not a configured root: ${p}"
        keep_r=(); keep_i=()
        for r in "${ROOTS[@]}";   do [[ "$r" == "$root" ]] || keep_r+=("$r"); done
        for i in "${IGNORES[@]}"; do [[ "$i" == "${root}/"* ]] || keep_i+=("$i"); done
        ROOTS=("${keep_r[@]}"); IGNORES=("${keep_i[@]}")
        success "root removed: ${root}"
    done
    save_config
}

cmd_roots() { load_config; local r; for r in "${ROOTS[@]}"; do printf '%s\n' "$r"; done; }

cmd_ignores() { load_config; local i; for i in "${IGNORES[@]}"; do printf '%s\n' "$i"; done; }

cmd_children() {
    (( $# == 1 )) || error_exit "children: give exactly one ROOT."
    load_config
    local root d name
    root="$(_resolve_root "$1")" || error_exit "children: not a configured root: $1"
    [[ -d "$root" ]] || error_exit "children: root not found on disk: ${root}"
    for d in "$root"/*/; do
        d="${d%/}"; name="${d##*/}"
        printf '%s\t%d\n' "$name" "$(_is_ignored "$d" && echo 1 || echo 0)"
    done
}

cmd_set_ignores() {
    (( $# >= 1 )) || error_exit "set-ignores: give a ROOT (then zero or more folder NAMEs)."
    load_config
    local root name i keep=()
    root="$(_resolve_root "$1")" || error_exit "set-ignores: not a configured root: $1"; shift
    for name in "$@"; do
        [[ -n "$name" && "$name" != */* && "$name" != . && "$name" != .. ]] \
            || error_exit "set-ignores: '${name}' must be a top-level folder name under the root (no '/')."
        [[ -d "${root}/${name}" ]] || error_exit "set-ignores: no such folder: ${root}/${name}"
    done
    for i in "${IGNORES[@]}"; do [[ "$i" == "${root}/"* ]] || keep+=("$i"); done
    IGNORES=("${keep[@]}")
    for name in "$@"; do _is_ignored "${root}/${name}" || IGNORES+=("${root}/${name}"); done
    save_config
    if (( $# )); then success "ignoring in ${root}: $*"; else success "no ignored folders in ${root}"; fi
}

cmd_repos() {
    load_config; discover
    local i
    for i in "${!REPO_LIST[@]}"; do printf '%s\t%s\n' "${REPO_ROOT[$i]}" "${REPO_LIST[$i]}"; done
}

cmd_config() {
    load_config
    printf 'config=%s\n' "$CONFIG_FILE"
    printf 'config_exists=%d\n' "$([[ -f "$CONFIG_FILE" ]] && echo 1 || echo 0)"
    printf 'onboarded=%s\n' "$ONBOARDED"
    printf 'roots=%d\n' "${#ROOTS[@]}"
    printf 'ignores=%d\n' "${#IGNORES[@]}"
}

cmd_mark_onboarded() { load_config; ONBOARDED=1; save_config; }

# Plain tree on stdout: per root, its repos (relative path, branch, dirty), the
# local branches tidy would delete, and its ignored folders.
#
# The tidy-able branches come from _tidy_plan_repo — the very function tidy
# plans with — rather than a second, similar-looking query here. Two
# implementations of "already merged" would eventually disagree, and status
# promising a deletion tidy then refuses (or hiding one it would make) is worse
# than not showing them at all.
cmd_status() {
    load_config
    (( ${#ROOTS[@]} )) || { echo "(no roots configured)"; return 0; }
    discover
    local root i entries=() kids=() rel br n k last cont line idx
    local total=0 repos_with=0 any_local_base=0
    for root in "${ROOTS[@]}"; do
        printf '%s\n' "${root/#$HOME/\~}"
        if [[ ! -d "$root" ]]; then echo "└── (folder not found)"; echo; continue; fi
        entries=(); kids=()
        for i in "${!REPO_LIST[@]}"; do
            [[ "${REPO_ROOT[$i]}" == "$root" ]] || continue
            rel="${REPO_LIST[$i]#"${root}"/}"; [[ "${REPO_LIST[$i]}" == "$root" ]] && rel="."
            br="$(_current_branch "${REPO_LIST[$i]}")" || br="(detached)"
            _is_dirty "${REPO_LIST[$i]}" && br+=" *"
            entries+=("$(printf '%-40s %s' "$rel" "[${br}]")")
            idx=$(( ${#entries[@]} - 1 ))

            # Costs nothing in the common case: a repo whose only branch is its
            # trunk plans no work, and the loop below never runs.
            TIDY_PLAN=(); TIDY_NOTES=()
            _tidy_plan_repo "${REPO_LIST[$i]}"
            if (( ${#TIDY_PLAN[@]} )); then
                repos_with=$(( repos_with + 1 ))
                local p prepo pbr pbase psha note kidlines=""
                for p in "${TIDY_PLAN[@]}"; do
                    IFS=$'\t' read -r prepo pbr pbase <<<"$p"
                    psha="$(git -C "$prepo" rev-parse --short "refs/heads/${pbr}" 2>/dev/null || echo '?')"
                    # A base that is not on origin is a weaker claim — the work
                    # is only known to be on this machine — so it is labelled
                    # rather than silently mixed in with the rest.
                    note=""
                    if [[ "$pbase" != origin/* ]]; then
                        note="  (vs the local ${pbase} — no origin)"; any_local_base=1
                    fi
                    kidlines+="$(printf -- '- %-38s %s%s' "$pbr" "$psha" "$note")"$'\n'
                    total=$(( total + 1 ))
                done
                kids[idx]="${kidlines%$'\n'}"
            fi
        done
        for i in "${IGNORES[@]}"; do
            [[ "$i" == "${root}/"* ]] && entries+=("${i#"${root}"/}/  (ignored)")
        done
        n=${#entries[@]}
        (( n )) || { echo "└── (no repositories found)"; echo; continue; }
        for k in "${!entries[@]}"; do
            last=$(( k == n - 1 ))
            printf '%s %s\n' "$( (( last )) && echo '└──' || echo '├──')" "${entries[$k]}"
            [[ -n "${kids[$k]:-}" ]] || continue
            # The last entry's children hang under nothing, so the guide line
            # stops with it.
            cont="$( (( last )) && printf '     ' || printf '│    ')"
            while IFS= read -r line; do printf '%s%s\n' "$cont" "$line"; done <<<"${kids[$k]}"
        done
        echo
    done
    echo "[branch *] = uncommitted changes"
    if (( total )); then
        printf -- '- branch   = already contained in the trunk on origin; %s.sh tidy deletes these\n' "$SCRIPT_NAME"
        (( any_local_base )) && printf -- '             (where a repo has no origin, against its local trunk instead)\n'
        printf -- '%d branch(es) in %d repo(s) can be tidied.\n' "$total" "$repos_with"
    fi
}

# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-}" args=()
    [[ $# -gt 0 ]] && shift
    while (( $# )); do
        case "$1" in
            --config)     [[ $# -ge 2 ]] || error_exit "--config needs a PATH"; CONFIG_FILE="$2"; shift 2 ;;
            --config=*)   CONFIG_FILE="${1#*=}"; shift ;;
            --repo)       [[ $# -ge 2 ]] || error_exit "--repo needs a PATH"; ONLY_REPO="$2"; shift 2 ;;
            --repo=*)     ONLY_REPO="${1#*=}"; shift ;;
            --dry-run)    DRY_RUN=1; shift ;;
            --tidy)       TIDY=1; shift ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; args+=("$@"); break ;;
            -*)           error_exit "unknown flag: $1 (see --help)" ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    case "$cmd" in
        maintain)       cmd_maintain ;;
        tidy)           cmd_tidy ;;
        prune)          cmd_prune "${args[@]}" ;;
        status)         cmd_status ;;
        roots)          cmd_roots ;;
        add-root)       cmd_add_root "${args[@]}" ;;
        remove-root)    cmd_remove_root "${args[@]}" ;;
        children)       cmd_children "${args[@]}" ;;
        ignores)        cmd_ignores ;;
        set-ignores)    cmd_set_ignores "${args[@]}" ;;
        repos)          cmd_repos ;;
        config)         cmd_config ;;
        mark-onboarded) cmd_mark_onboarded ;;
        version)        echo "${SCRIPT_NAME} ${VERSION}" ;;
        ""|-h|--help|help) usage; [[ -n "$cmd" ]] ;;
        *)              usage; error_exit "unknown command: ${cmd}" ;;
    esac
}

main "$@"
