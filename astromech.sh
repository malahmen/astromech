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
#   - on another long-lived branch (git-flow's main, release/*, stable) with
#     local changes: skip the repo - never a wip commit there
#   - then: git pull --rebase
#
# Nothing is pushed. A failed step is reported and the repo is left exactly as
# that step left it — a stopped rebase stays stopped for whoever ran
# maintenance to resolve — and the run moves on to the next repo. Up to
# --jobs repos (default 4) are maintained at once; --jobs 1 is one at a time.
# Each repo is one line, printed in order (on a terminal, drawn live while it
# runs). Repos that are mid-rebase/merge, on a detached HEAD, or have neither
# main nor master are skipped and reported, never touched.
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
# Requirements: bash >= 4, git >= 2.23 (for-each-ref's %(worktreepath), which
# tidy relies on to leave checked-out branches alone; checked at start). Run
# --help for the command list.
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
VERSION="1.2.0"

# ---- gum-free status output (stderr; stdout stays clean for data) ------------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Unattended runs (cron, a systemd timer) get a leading UTC timestamp, since a
# mail spool or a log file has no other clock; a terminal already has one, and
# gets colour instead.
if [[ -t 2 ]]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
    _pfx() { printf ''; }
else
    C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""
    _pfx() { printf '%s ' "$(_ts)"; }
fi

info()       { printf '%s%s[info]%s  %s\n'  "$(_pfx)" "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s%s[ok]%s    %s\n'  "$(_pfx)" "$C_G" "$C_N" "$*" >&2; }
# _NWARN counts what warned or failed, so a repo's buffered report can be shown
# under its line when something in it asks to be read (Kamino item 240).
_NWARN=0
warn()       { _NWARN=$(( _NWARN + 1 )); printf '%s%s[warn]%s  %s\n'  "$(_pfx)" "$C_Y" "$C_N" "$*" >&2; }
error()      { _NWARN=$(( _NWARN + 1 )); printf '%s%s[error]%s %s\n'  "$(_pfx)" "$C_R" "$C_N" "$*" >&2; }
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
JOBS=""            # --jobs N; empty = the config's jobs=, else JOBS_DEFAULT
JOBS_DEFAULT=4
JOBS_MAX=64

# ---- config (filled by load_config) -----------------------------------------
ROOTS=()
IGNORES=()
ONBOARDED=0
CONF_JOBS=""       # jobs= as written in the config (validated when used)

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
  --jobs N                 maintain, tidy, status: repos worked on at once, 1-${JOBS_MAX}
                           (default ${JOBS_DEFAULT}, or jobs= in the config); 1 = one at a time
  --dry-run                prune: report the change, write nothing
  -y, --yes                tidy: delete without asking (required when there is no terminal)
  -v, --verbose            maintain, tidy: every repo's steps under its line; debug logging
  -h, --help

Per repo, maintain does:
  feature branch  -> git add -A; git commit (auto message); git checkout main|master
  main|master     -> if dirty: git stash push -u (the stash is left for you)
  then            -> git pull --rebase
A long-lived branch that is not the trunk (main, release/*, stable in a git-flow
repo whose origin/HEAD is develop) is never committed on: dirty, it is skipped.
Nothing is pushed. A failed step leaves the repo as that step left it (a stopped
rebase stays stopped for you to resolve) and the run moves on. Repos mid-rebase/
merge, on a detached HEAD, or with neither main nor master are skipped.

Each repo is one line - "name  ok: what was done", "skipped: why", "FAILED:
why" - printed once it and every repo before it are done, so the output reads
the same with any --jobs; git's own output is shown under a line that failed,
and --verbose shows every step. On a terminal the repos still running are drawn
in place below the finished ones. With more than one job nothing may prompt:
GIT_TERMINAL_PROMPT=0, and ssh runs with -o BatchMode=yes (added to
GIT_SSH_COMMAND or core.sshCommand), so credentials must come from ssh-agent or
a credential helper, as under cron; a repo that would ask fails instead.

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
    ROOTS=(); IGNORES=(); ONBOARDED=0; CONF_JOBS=""
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
            jobs)      CONF_JOBS="$val" ;;
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
        [[ -z "$CONF_JOBS" ]] || echo "jobs=${CONF_JOBS}"
        for r in "${ROOTS[@]}";   do echo "root=${r}"; done
        for i in "${IGNORES[@]}"; do echo "ignore=${i}"; done
    } > "$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

_jobs_valid() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= JOBS_MAX )); }

# _jobs — echoes how many repos maintain runs at once: --jobs, else the
# config's jobs=, else the default. A bad jobs= in the config is named and
# ignored rather than fatal: a typo there must not stop every cron run.
_jobs() {
    if [[ -n "$JOBS" ]]; then printf '%d' "$((10#$JOBS))"; return; fi
    if [[ -n "$CONF_JOBS" ]]; then
        if _jobs_valid "$CONF_JOBS"; then printf '%d' "$((10#$CONF_JOBS))"; return; fi
        warn "config: jobs=${CONF_JOBS} is not a number from 1 to ${JOBS_MAX} — using ${JOBS_DEFAULT}"
    fi
    printf '%d' "$JOBS_DEFAULT"
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

# _ignore_in IGNORE ROOT — the ignore is one of ROOT's own top-level folders.
# By parent, not by prefix: with ~/code and ~/code/work both configured, a
# prefix test reads ~/code/work/tmp as ~/code's too, and clearing or removing
# ~/code then silently drops ~/code/work's ignores.
_ignore_in() { [[ "${1%/*}" == "$2" ]]; }

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

# What discovery learnt of each repository, by path: its absolute git dir
# (RGD) and whether it is a work tree (RWT, rev-parse's true/false). One
# 'git rev-parse' per directory answers the git dir, the common dir and the
# work-tree question at once; it took four calls before (Kamino item 239):
# two to tell a linked worktree, one more for the common dir, and maintain's
# or tidy's --is-inside-work-tree later. Unset when rev-parse failed: the
# helpers below then ask git again, as they did before, and fail the same way.
declare -A RGD=() RWT=()

# _rev_parse REPO — sets RP_KEY (the repository's shared git directory,
# absolute and canonical: one per repository, the same for every worktree of
# it - or REPO when git cannot say) and RP_LINKED (1 for a linked worktree,
# `git worktree add`: a git dir of its own under the shared one; a submodule,
# whose .git is also a file, does not have one).
_rev_parse() {
    local repo="$1" out wt="" gd="" c="" cd
    RP_KEY="$repo"; RP_LINKED=0
    out="$(git -C "$repo" rev-parse --is-inside-work-tree --absolute-git-dir --git-common-dir 2>/dev/null)" || return 0
    { IFS= read -r wt; IFS= read -r gd; IFS= read -r c; } <<<"$out"
    RWT[$repo]="$wt"; RGD[$repo]="$gd"
    cd="$(cd "$repo" && cd "$c" && pwd -P)" || return 0
    RP_KEY="$cd"
    [[ "$(cd "$gd" && pwd -P)" != "$cd" ]] && RP_LINKED=1
    return 0
}

# The deepest configured root holding REPO: with nested roots, status listed a
# repo under whichever root was walked first (Kamino item 142).
_deepest_root() {
    local repo="$1" r best=""
    for r in "${ROOTS[@]}"; do
        if [[ "$repo" == "$r" || "$repo" == "$r"/* ]] && (( ${#r} > ${#best} )); then best="$r"; fi
    done
    printf '%s' "$best"
}

# Fills REPO_LIST / REPO_ROOT / REPO_KEY (parallel arrays), one entry per
# repository; REPO_KEY is its shared git dir (or its path, if git cannot say).
#
# A linked worktree is part of its repository, not a second one: discovered as
# one, status listed its branch twice, tidy deleted it from one side and then
# reported git's refusal on the other - every cron --tidy run failed and
# suggested -D - and maintain would have wip-committed on it (Kamino item
# 141). So they are skipped, and repositories are told apart by their shared
# git dir rather than by path.
#
# A linked worktree whose repository was NOT found under any root is the
# exception that must not vanish without a word (Kamino item 193): it is
# named, with the reason, on every run. It is still not maintained - its trunk
# is checked out in the primary worktree, so the checkout would fail, and a
# wip commit on its branch is exactly what item 141 removed. Covering it means
# adding the repository's own folder as a root.
REPO_LIST=(); REPO_ROOT=(); REPO_KEY=()
discover() {
    REPO_LIST=(); REPO_ROOT=(); REPO_KEY=()
    local -A seen=() orphans=()
    local root repo key
    for root in "${ROOTS[@]}"; do
        if [[ ! -d "$root" ]]; then warn "root not found (skipped): ${root}"; continue; fi
        while IFS= read -r repo; do
            _rev_parse "$repo"; key="$RP_KEY"
            if (( RP_LINKED )); then
                dbg "linked worktree, part of ${key}: ${repo}"
                orphans[$repo]="$key"
                continue
            fi
            [[ -n "${seen[$key]:-}" ]] && continue
            seen[$key]=1
            REPO_LIST+=("$repo"); REPO_ROOT+=("$(_deepest_root "$repo")"); REPO_KEY+=("$key")
        done < <(_walk "$root" 0)
    done
    local primary
    for repo in "${!orphans[@]}"; do
        key="${orphans[$repo]}"
        [[ -n "${seen[$key]:-}" ]] && continue
        primary="$key"; [[ "$primary" == */.git ]] && primary="${primary%/.git}"
        warn "linked worktree not maintained: ${repo/#$HOME/\~} belongs to ${primary/#$HOME/\~}, which is under no root (or is ignored) - add that folder as a root to cover it"
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

# _stashes REPO — how many of astromech's own stashes the repo holds. Each run
# that finds the trunk dirty adds one and none is ever popped, so under cron
# they pile up unless something says so.
_stashes() { git -C "$1" stash list --format=%gs 2>/dev/null | grep -c 'astromech: before pull' || true; }

_current_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }

# _work_tree REPO — rev-parse's answer to --is-inside-work-tree (true/false),
# from discovery when it has it.
_work_tree() {
    if [[ -n "${RWT[$1]+x}" ]]; then printf '%s' "${RWT[$1]}"; return 0; fi
    git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null || true
}

# _snap REPO [status] — one read of what maintain, tidy and status ask about a
# repository's HEAD and refs (Kamino item 239). It used to be a git call per
# question: symbolic-ref for the branch, status for dirt, stash list, then
# symbolic-ref and up to six show-refs for the trunk, one more show-ref for
# the base, one rev-parse per listed sha. Now:
#
#   - one for-each-ref over refs/heads, refs/remotes/origin and refs/stash:
#     every local branch with its short sha and the worktree it is checked out
#     in, the current branch (%(HEAD), shortened exactly as symbolic-ref
#     --short shortens it), which origin/* exist, origin/HEAD's target, and
#     whether there is a stash at all;
#   - with 'status', one `git status --porcelain=v2 --branch` for the dirty
#     state, and for detached vs. unborn when no branch is current.
#
# Sets S_REPO, S_HASBR/S_BR (on a branch / its name), S_DIRTY, S_OHEAD
# (origin/HEAD's target, short), S_HEADS (branches, in for-each-ref's order),
# S_REF[full refname]=short sha and S_WTP[branch]=worktree path. A snapshot is
# for reading: whoever changes the repo (maintain_repo) clears S_REPO.
S_REPO=""; S_HASBR=0; S_BR=""; S_DIRTY=0; S_OHEAD=""; S_HEADS=()
declare -A S_REF=() S_WTP=()
_snap() {
    local repo="$1" mode="${2:-refs}" st="" strc=0 line head="" ohead=0
    local ref hd short sha sym wtp gd="${RGD[$1]-}"
    S_REPO=""; S_HASBR=0; S_BR=""; S_DIRTY=0; S_OHEAD=""; S_HEADS=()
    declare -gA S_REF=() S_WTP=()
    if [[ "$mode" == status ]]; then
        st="$(git -C "$repo" status --porcelain=v2 --branch --no-ahead-behind 2>/dev/null)" || strc=1
        while IFS= read -r line; do
            case "$line" in
                "# branch.head "*) head="${line#\# branch.head }" ;;
                "#"*|"") ;;
                *) S_DIRTY=1 ;;
            esac
        done <<<"$st"
    fi
    while IFS=$'\x1f' read -r ref hd short sha sym wtp; do
        case "$ref" in
            refs/heads/*)
                S_HEADS+=("${ref#refs/heads/}"); S_WTP[${ref#refs/heads/}]="$wtp"
                [[ "$hd" == '*' ]] && { S_HASBR=1; S_BR="$short"; } ;;
            refs/remotes/origin/HEAD) S_OHEAD="$sym"; ohead=1 ;;
            "") continue ;;
        esac
        S_REF[$ref]="$sha"
    done < <(git -C "$repo" for-each-ref \
        --format='%(refname)%1f%(HEAD)%1f%(refname:short)%1f%(objectname:short)%1f%(symref:short)%1f%(worktreepath)' \
        refs/heads/ refs/remotes/origin/ refs/stash 2>/dev/null)
    # No branch is current: detached, or a branch with no commit yet (which
    # status names and for-each-ref cannot list). Only the second asks git.
    if (( ! S_HASBR )) && ! [[ "$mode" == status && "$strc" == 0 && "$head" == "(detached)" ]]; then
        if S_BR="$(_current_branch "$repo")"; then S_HASBR=1; else S_BR=""; fi
    fi
    # for-each-ref leaves out a symref whose target is gone, and a stale
    # origin/HEAD is one _default_branch has to see. Symrefs are never packed,
    # so with the files backend no file means no origin/HEAD at all.
    if (( ! ohead )) && [[ -z "$gd" || -e "${gd}/refs/remotes/origin/HEAD" || -L "${gd}/refs/remotes/origin/HEAD" || -d "${gd}/reftable" ]]; then
        S_OHEAD="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    fi
    S_REPO="$repo"
}

# _has_ref FULLNAME — the last snapshot holds it.
_has_ref() { [[ -n "${S_REF[$1]+x}" ]]; }

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
#
# Read from the repo's snapshot (taken here if the last one is another repo's).
_default_branch() {
    local repo="$1" b head
    [[ "${S_REPO:-}" == "$repo" ]] || _snap "$repo"

    head="${S_OHEAD#origin/}"
    if [[ -n "$head" ]]; then
        # Validated, not trusted: origin/HEAD can be a stale symref left
        # pointing at a branch that has since been deleted, and naming a
        # branch that does not exist would fail the checkout later instead of
        # here.
        if _has_ref "refs/heads/${head}" || _has_ref "refs/remotes/origin/${head}"; then
            printf '%s' "$head"; return 0
        fi
    fi

    if (( S_HASBR )); then
        case "$S_BR" in
            main|master) printf '%s' "$S_BR"; return 0 ;;
        esac
    fi

    for b in main master; do
        if _has_ref "refs/heads/${b}"; then printf '%s' "$b"; return 0; fi
    done
    for b in main master; do
        if _has_ref "refs/remotes/origin/${b}"; then printf '%s' "$b"; return 0; fi
    done
    return 1
}

# Echoes the name of an operation in progress (rebase, merge, …), or nothing.
_in_progress() {
    local gd="${RGD[$1]-}"
    [[ -n "$gd" ]] || gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "unreadable git dir"; return; }
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
# Not printed here: the repo's one line says it (Kamino item 240).
R_STATUS=""; R_NOTE=""
_ok()   { R_STATUS=ok;      R_NOTE="$1"; }
_skip() { R_STATUS=skipped; R_NOTE="$1"; }
_fail() { R_STATUS=failed;  R_NOTE="$1"; }

maintain_repo() {
    local repo="$1" op branch def dirty notes=() stamp
    stamp="$(date +%F)"

    if [[ "$(_work_tree "$repo")" != true ]]; then
        _skip "not a git work tree"; return
    fi
    op="$(_in_progress "$repo")"
    [[ -n "$op" ]] && { _skip "${op} in progress — finish or abort it first"; return; }
    _snap "$repo" status
    (( S_HASBR )) || { _skip "detached HEAD"; return; }
    branch="$S_BR"
    def="$(_default_branch "$repo")"    || { _skip "no main or master branch"; return; }
    dirty="$S_DIRTY"
    # Everything below changes the repo: nothing may read this snapshot again.
    S_REPO=""

    # A long-lived branch that is not the trunk (git-flow: main, release/*,
    # stable while origin/HEAD names develop) is never wip-committed on: the
    # next push would publish the commit (Kamino item 170). Skipped, not
    # stashed - a stash would hide the work and the checkout would then move
    # the person off the branch they were deliberately on (a hotfix on main);
    # skipping changes nothing, and the summary says why.
    if [[ "$branch" != "$def" ]] && _tidy_keep "$branch" && (( dirty )); then
        _skip "uncommitted changes on the long-lived branch '${branch}' (trunk: '${def}') — never auto-committed; commit or stash them yourself"
        return
    fi

    if [[ "$branch" != "$def" ]]; then
        if (( dirty )); then
            if (( DRY_RUN )); then
                info "would commit all changes on '${branch}'"
            else
                _phase committing
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
            _phase "checking out"
            # '--': a tracked file named like the trunk makes a bare
            # 'checkout main' ambiguous whenever main exists only on origin,
            # and git then refuses it on every run.
            _git "$repo" checkout -q "$def" -- || { _fail "checkout '${def}' failed (still on '${branch}')"; return; }
            info "checked out '${def}' (was '${branch}')"
        fi
        notes+=("${branch} → ${def}")
    elif (( dirty )); then
        if (( DRY_RUN )); then
            info "would stash local changes on '${def}'"
        else
            _phase stashing
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

    _phase pulling
    if ! _git "$repo" pull -q --rebase; then
        if [[ "$(_in_progress "$repo")" == rebase ]]; then
            _fail "pull --rebase stopped on a conflict — left mid-rebase for you (git status; rebase --continue/--abort)"
        else
            _fail "pull --rebase failed on '${def}' (no upstream? offline?)"
        fi
        return
    fi
    info "pulled '${def}'"
    notes+=("pulled")
    local joined; joined="$(IFS=,; echo "${notes[*]}")"
    _ok "${joined//,/, }"
}

# A run lock, so a cron run and a manual one cannot interleave. Two astromech
# processes in the same repository is one way an index.lock becomes "stale" in
# the first place: one of them is holding it legitimately while the other
# reports it as wreckage.
#
# One fixed path per user, under $HOME (Kamino item 193). It used to live under
# XDG_RUNTIME_DIR when set, else TMPDIR: cron sets neither while a desktop
# session sets the first, so the cron run and the interactive one each took a
# lock of their own and excluded nothing. XDG_STATE_HOME is not honoured for
# the same reason - it is set by a login profile and absent under cron. $HOME
# is set in both.
#
# A file created by link(2), not flock(1) (macOS ships none) nor mkdir. The pid
# is written to a temporary file first and that file is then linked into place,
# which is atomic and fails if the lock exists: the lock never exists without
# its pid. With mkdir-then-write, a second run arriving in between read an
# empty pid, called the lock stale and removed it from under its live holder.
#
# The lock outlives a reboot (it is no longer on a tmpfs), so it records the
# boot too: after a reboot its pid may belong to some unrelated new process,
# which must not block maintenance forever.
_LOCK_FILE=""
_lock_path() { printf '%s/.local/state/astromech/run.lock' "$HOME"; }

_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null \
        || sysctl -n kern.boottime 2>/dev/null \
        || true
}

# _lock_take FILE — 0 when FILE was created holding this run's pid and boot.
_lock_take() {
    local f="$1" tmp rc=0
    tmp="$(mktemp "${f%/*}/.run.lock.XXXXXX")" || return 1
    printf '%s\n%s\n' "$$" "$(_boot_id)" > "$tmp" || rc=1
    (( rc )) || ln "$tmp" "$f" 2>/dev/null || rc=1
    rm -f "$tmp"
    return "$rc"
}

_run_lock() {
    local f pid="" boot=""; f="$(_lock_path)"
    mkdir -p "${f%/*}" 2>/dev/null || { error "cannot create ${f%/*}"; return 1; }
    # ln onto a directory would create a link inside it and "succeed".
    [[ -d "$f" ]] && { error "${f} is a directory, not a lock file"; return 1; }
    _lock_take "$f" && { _LOCK_FILE="$f"; return 0; }
    # Held — or abandoned. A holder that no longer exists must not block
    # maintenance forever: that turns one killed run into a silent stop.
    local held old cur=""
    held="$(cat "$f" 2>/dev/null)" || held=""
    # Gone since (its holder finished): just try again. Present but empty
    # cannot come from a live run any more, so it is stale like a dead pid.
    if [[ -e "$f" ]]; then
        { IFS= read -r pid; IFS= read -r boot; } <<< "$held"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
            && { [[ -z "$boot" ]] || [[ "$boot" == "$(_boot_id)" ]] || [[ -z "$(_boot_id)" ]]; }; then
            return 1
        fi
        # Moved aside, not removed, and checked: a second run that judged the
        # same lock stale may already have replaced it with its own live one.
        old="${f}.stale.$$"
        mv -f "$f" "$old" 2>/dev/null || return 1
        cur="$(cat "$old" 2>/dev/null)" || cur=""
        if [[ "$cur" != "$held" ]]; then
            ln "$old" "$f" 2>/dev/null || true
            rm -f "$old"
            return 1
        fi
        rm -f "$old"
        warn "removing a stale run lock (${f}; pid ${pid:-unknown} is gone)"
    fi
    _lock_take "$f" || return 1
    _LOCK_FILE="$f"
}

_release_lock() { [[ -n "$_LOCK_FILE" ]] && rm -f "$_LOCK_FILE"; _LOCK_FILE=""; }

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
    trap '_on_exit' EXIT
    load_config
    (( ${#ROOTS[@]} )) || error_exit "No roots configured. Add one: ${SCRIPT_NAME}.sh add-root PATH"
    discover

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

    local jobs; jobs="$(_jobs)"
    (( jobs <= ${#targets[@]} )) || jobs=${#targets[@]}

    local n_ok=0 n_skip=0 n_fail=0 lines=() stashed=()
    if (( jobs > 1 )); then
        # Nothing may prompt with several repos at once (see below).
        export GIT_TERMINAL_PROMPT=0
        info "Up to ${jobs} repos at a time (--jobs 1 for one at a time). Nothing may prompt: GIT_TERMINAL_PROMPT=0 and ssh -o BatchMode=yes, so credentials must come from ssh-agent or a credential helper."
        if [[ -n "${GIT_SSH:-}" && -z "${GIT_SSH_COMMAND:-}" ]]; then
            warn "GIT_SSH is set (${GIT_SSH}): a program, so BatchMode cannot be added to it - it must not prompt either. GIT_SSH_COMMAND would let astromech add it."
        fi
    fi
    _live_init
    _PAR_KIND=maintain _PH0=checking
    _par_run "$jobs" "${targets[@]}"

    printf '\n' >&2
    info "Summary: ${n_ok} ok, ${n_skip} skipped, ${n_fail} failed."
    if (( TIDY )); then info "Tidy: ${TIDY_DELETED} branch(es) deleted, ${TIDY_FAILED} refused."; fi
    local l
    (( ${#stashed[@]} )) && info "Stashes: ${#stashed[@]} repo(s) hold changes astromech stashed and nobody has picked up."
    for l in "${lines[@]}" "${TIDY_LINES[@]}" "${stashed[@]}"; do printf '          %s\n' "$l" >&2; done
    (( n_fail == 0 && TIDY_FAILED == 0 ))
}

# _maintain_one I — one repo's whole job: maintain_repo, then its tidy. Leaves
# R_STATUS/R_NOTE and adds to TIDY_DELETED/TIDY_FAILED/TIDY_LINES.
_maintain_one() {
    local i="$1"
    maintain_repo "${REPO_LIST[$i]}"
    # Only after a repo came back clean and up to date: the pull is what makes
    # origin/<trunk> current, and tidying against a stale one would spare
    # branches it already holds. A repo that was skipped or failed keeps all
    # of its branches.
    if [[ "$R_STATUS" == ok ]] && (( TIDY )); then
        _phase tidying
        TIDY_PLAN=(); TIDY_NOTES=()
        _tidy_plan_repo "${REPO_LIST[$i]}"
        if (( DRY_RUN )); then _tidy_print_plan
        else _tidy_apply; fi
    fi
    return 0
}

# _maintain_tally I STASHES — counts the result of repo I (R_STATUS/R_NOTE)
# into cmd_maintain's totals and summary lines.
_maintain_tally() {
    local i="$1" ns="$2"
    case "$R_STATUS" in
        ok)      n_ok=$((n_ok + 1)) ;;
        skipped) n_skip=$((n_skip + 1));  lines+=("skipped  ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
        failed)  n_fail=$((n_fail + 1));  lines+=("FAILED   ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
    esac
    (( ns )) && stashed+=("stashes  ${REPO_LIST[$i]/#$HOME/\~}: ${ns} kept (git -C ${REPO_LIST[$i]/#$HOME/\~} stash list)")
    return 0
}

# _maintain_body K — maintains _PAR_TG[K] (in a job, or in-process with
# --jobs 1) and writes its result: status, note, tidy's counts, the stash
# count, how many warnings it printed, how many branches tidy planned, then
# tidy's REFUSED lines. Tidy's counters are local: the parent adds them up
# from the result, whichever way the repo ran.
_maintain_body() {
    local k="$1" i="${_PAR_TG[$1]}" ns
    local TIDY_DELETED=0 TIDY_FAILED=0 TIDY_LINES=() TIDY_PLAN=() TIDY_NOTES=() TIDY_DONE=() TIDY_REFUSED=() _NWARN=0
    _maintain_one "$i"
    ns="$(_stashes "${REPO_LIST[$i]}")"
    _par_result "$k" "$R_STATUS" "$R_NOTE" "$TIDY_DELETED" "$TIDY_FAILED" "$ns" "$_NWARN" "${#TIDY_PLAN[@]}" "${TIDY_LINES[@]}"
}

# _maintain_text — the state word and note of the result in _RES.
_maintain_text() {
    case "${_RES[0]}" in ok) _TS=ok ;; skipped) _TS=skipped ;; *) _TS=FAILED ;; esac
    _TN="${_RES[1]}"
    if [[ "${_RES[0]}" == ok ]] && (( TIDY )); then
        if (( DRY_RUN )); then
            (( _RES[6] )) && _TN+=", $(_nbr "${_RES[6]}") would be deleted"
        else
            (( _RES[2] )) && _TN+=", $(_nbr "${_RES[2]}") deleted"
            (( _RES[3] )) && _TN+=", ${_RES[3]} refused"
        fi
    fi
    return 0
}

_flush_maintain() {
    local k="$1" rc="$2" i="${_PAR_TG[$1]}" ns details="$VERBOSE"
    if _res_read "$k"; then
        R_STATUS="${_RES[0]}"; R_NOTE="${_RES[1]}"; ns="${_RES[4]}"
        TIDY_DELETED=$(( TIDY_DELETED + _RES[2] )); TIDY_FAILED=$(( TIDY_FAILED + _RES[3] ))
        (( ${#_RES[@]} > 7 )) && TIDY_LINES+=("${_RES[@]:7}")
        # Something to read beyond the line: a refusal, or a warning.
        (( _RES[3] || _RES[5] )) && details=1
    else
        R_STATUS=failed
        R_NOTE="maintenance stopped unexpectedly (exit ${rc}) — the repo may be mid-step; look at it with git status"
        ns="$(_stashes "${REPO_LIST[$i]}")"
        _RES=(failed "$R_NOTE" 0 0 "$ns" 0 0)
    fi
    [[ "$R_STATUS" == failed ]] && details=1
    _maintain_text
    _par_emit "$k" "$_TS" "$_TN" "$details"
    _maintain_tally "$i" "$ns"
}

# -----------------------------------------------------------------------------
# The job runner: several repos at once (Kamino item 238), one line each
# (Kamino items 240, 241)
# -----------------------------------------------------------------------------
#
# A pull is network-bound, so one repo at a time made a run as long as the sum
# of its pulls. With --jobs N, up to N repos run their whole job at once, each
# in a background subshell. The runner serves maintain (each repo's
# maintain_repo and its tidy), tidy's planning and its deletions, and status
# (each repo's rows), told apart by _PAR_KIND:
#
#   - a job's output goes to a buffer of its own, and its result to a file - a
#     subshell cannot set the parent's globals. The parent prints a repo once
#     it and every repo before it are done, so the report is in repo order
#     whatever finished first, and --jobs 1 (each repo in-process, buffered
#     the same way) prints the same bytes;
#   - each repo is one line: "name  ok: notes", "skipped: why", "FAILED: why".
#     The buffer - the steps taken, git's own output - is printed under the
#     line only when there is something to read in it: the repo failed, tidy
#     was refused, or something warned; --verbose prints it for every repo;
#   - on a terminal the repos still running are drawn as a live block under
#     the finished lines and redrawn in place (_live_*);
#   - two repos whose git dirs are the same or nested are never maintained at
#     once. One entry per git dir is already discovery's rule; a submodule's
#     git dir (inside the superproject's .git/modules) is the nested case,
#     written by the superproject's own pull too
#     (fetch.recurseSubmodules=on-demand). Reading (status, tidy's plan) has
#     no such rule;
#   - nothing may prompt: no one could answer, and a background job reading the
#     terminal would stop the run for good. GIT_TERMINAL_PROMPT=0, ssh gets
#     -o BatchMode=yes, stdin is /dev/null, and SIGTTIN/SIGTTOU are ignored so
#     anything else that opens /dev/tty gets an error rather than a stop;
#   - a job that dies without its result - errexit, a signal - is that repo's
#     failure, never the run's (Kamino item 170's rule, kept here);
#   - each job is its own process group, so Ctrl-C/TERM/HUP stops the jobs and
#     every git under them, and the EXIT trap still releases the run lock.

_PAR_KIND=""; _PH0=""   # what runs per repo: maintain|plan|delete|status; a job's first phase
_PAR_DIR=""; _PAR_TG=(); _PAR_PID=(); _PAR_STATE=()   # 0 waiting, 1 running, 2 done, 3 printed
_PAR_N=0; _PAR_DONE=0; _PAR_CUR=0; _PAR_T0=(); _PAR_PH=(); _PAR_LS=(); _PAR_LN=()
_PHASE_FILE=""; _RES=(); _TS=""; _TN=""; _NAME=(); _NAMEW=0

_par_cleanup() { [[ -z "$_PAR_DIR" ]] || rm -rf "$_PAR_DIR"; _PAR_DIR=""; }

_on_exit() { _live_restore; _par_cleanup; _release_lock; return 0; }

_nbr() { if (( $1 == 1 )); then printf '1 branch'; else printf '%d branches' "$1"; fi; }

# _phase WHAT — the step a repo's job is on ("pulling"), for the live line.
_phase() {
    if [[ -n "$_PHASE_FILE" ]]; then printf '%s' "$1" > "$_PHASE_FILE" 2>/dev/null || true; fi
    if (( _LIVE_LINE )); then _live_running "$_PAR_CUR" "$1"; fi
    return 0
}

# _batch_ssh REPO — makes ssh non-interactive for REPO's git without losing
# the ssh command it would have used: GIT_SSH_COMMAND, else core.sshCommand
# (git's own order), else plain ssh. GIT_SSH names a program, which cannot be
# given options; it is left alone (and said so once, in cmd_maintain).
_batch_ssh() {
    local cmd="${GIT_SSH_COMMAND:-}"
    if [[ -z "$cmd" ]]; then
        cmd="$(git -C "$1" config --get core.sshCommand 2>/dev/null || true)"
        [[ -z "$cmd" && -n "${GIT_SSH:-}" ]] && return 0
    fi
    export GIT_SSH_COMMAND="${cmd:-ssh} -o BatchMode=yes"
}

# _par_result K FIELD... — job K's result, written last and renamed into
# place: no file means the job did not finish.
_par_result() {
    local f="${_PAR_DIR}/$1.res"; shift
    printf '%s\0' "$@" > "${f}.tmp"
    mv -f "${f}.tmp" "$f"
}

# _res_read K — job K's result into _RES; 1 when there is none.
_res_read() {
    local f="${_PAR_DIR}/$1.res" x
    _RES=()
    [[ -f "$f" ]] || return 1
    while IFS= read -r -d '' x; do _RES+=("$x"); done < "$f"
    return 0
}

_par_body() {
    case "$_PAR_KIND" in
        maintain) _maintain_body "$1" ;;
        plan)     _plan_body "$1" ;;
        delete)   _delete_body "$1" ;;
        status)   _status_body "$1" ;;
    esac
}

# _par_job K — the background job for _PAR_TG[K].
_par_job() {
    local k="$1"
    trap - EXIT INT TERM HUP WINCH
    trap '' TTIN TTOU
    _LIVE=0; _LIVE_LINE=0; _LIVE_BLOCK=0; _LIVE_HID=0; _LIVE_OPEN=0
    _PHASE_FILE="${_PAR_DIR}/${k}.phase"
    if [[ "$_PAR_KIND" == maintain ]]; then _batch_ssh "${REPO_LIST[${_PAR_TG[$k]}]}"; fi
    _par_body "$k"
}

# _par_conflict K — 0 when a running job's git dir is K's, or holds it, or
# lies inside it.
_par_conflict() {
    local a="${REPO_KEY[${_PAR_TG[$1]}]}" b m
    for m in "${!_PAR_STATE[@]}"; do
        (( _PAR_STATE[m] == 1 )) || continue
        b="${REPO_KEY[${_PAR_TG[$m]}]}"
        [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]] && return 0
    done
    return 1
}

_par_spawn() {
    local k="$1" d="$_PAR_DIR"
    # Job control on for the fork only: each job then gets a process group of
    # its own, which _par_abort can signal whole.
    set -m
    ( _par_job "$k" ) </dev/null >"${d}/${k}.out" 2>"${d}/${k}.err" &
    _PAR_PID[k]=$!
    set +m
    _PAR_STATE[k]=1; _PAR_T0[k]=$SECONDS
}

# _par_emit K STATE NOTE DETAILS — repo K's line, for good; then its buffer
# when DETAILS is 1 (all of it with --verbose), then what it wrote on stdout
# (tidy's plan in a dry run).
_par_emit() {
    local k="$1" d="$_PAR_DIR"
    _state_style "$2"
    _row "${_PAR_TG[$k]}" "$2" "$3" "$_SYM" "$_COL" 1
    if (( _LIVE )); then printf '\r\033[2K%s\n' "$_ROW" >&"$_LIVE_FD"; _LIVE_OPEN=0
    else printf '%s\n' "$_ROW" >&2; fi
    # The steps taken ([info]) only with --verbose: otherwise what is shown
    # is what explains the line - git's own words, a warning.
    if (( $4 )) && [[ -s "${d}/${k}.err" ]]; then
        if (( VERBOSE )); then cat "${d}/${k}.err" >&2
        else grep -vF '[info]' "${d}/${k}.err" >&2 || true; fi
    fi
    if [[ -s "${d}/${k}.out" ]]; then cat "${d}/${k}.out"; fi
    return 0
}

# _par_flush K RC — prints job K (in repo order) and counts its result.
_par_flush() {
    (( _LIVE_BLOCK )) && _live_clear
    case "$_PAR_KIND" in
        maintain) _flush_maintain "$1" "$2" ;;
        plan)     _flush_plan "$1" "$2" ;;
        delete)   _flush_delete "$1" "$2" ;;
        status)   _flush_status "$1" "$2" ;;
    esac
    _PAR_STATE[$1]=3
}

# _par_cache K RC — the final state of a job that is done but not yet printed
# (one before it is still running), for the live block.
_par_cache() {
    local k="$1" rc="$2"
    if _res_read "$k"; then
        case "$_PAR_KIND" in
            maintain) _maintain_text ;;
            plan)     _TS=planned; if (( _RES[0] )); then _TN="$(_nbr "${_RES[0]}") merged"; else _TN="nothing to delete"; fi ;;
            *)        _TS=ok; _TN="" ;;
        esac
    else
        _TS=FAILED; _TN="stopped unexpectedly (exit ${rc})"
    fi
    _PAR_LS[k]="$_TS"; _PAR_LN[k]="$_TN"
}

# _par_alive K... — 0 while anything in one of these jobs' process groups runs.
_par_alive() {
    local k
    for k in "$@"; do kill -0 -- "-${_PAR_PID[k]}" 2>/dev/null && return 0; done
    return 1
}

# _par_abort SIGNAL — the INT/TERM/HUP trap while jobs run: stop every job's
# process group, print what the started repos reported, and exit; the EXIT
# trap then removes the buffers, puts the cursor back and releases the run
# lock.
_par_abort() {
    local sig="$1" k n det code=130 stopped=() names=()
    trap '' INT TERM HUP
    set +m   # in case the signal landed inside _par_spawn
    case "$sig" in TERM) code=143 ;; HUP) code=129 ;; esac
    for k in "${!_PAR_STATE[@]}"; do
        (( _PAR_STATE[k] == 1 )) || continue
        kill -TERM -- "-${_PAR_PID[k]}" 2>/dev/null || true
        stopped+=("$k")
    done
    # A few seconds for git to remove its own lock files, then no more.
    for (( n = 0; n < 50; n++ )); do
        (( ${#stopped[@]} )) && _par_alive "${stopped[@]}" || break
        sleep 0.1
    done
    for k in "${stopped[@]}"; do
        kill -KILL -- "-${_PAR_PID[k]}" 2>/dev/null || true
        wait "${_PAR_PID[k]}" 2>/dev/null || true
    done
    (( _LIVE_BLOCK )) && _live_clear
    if [[ "$_PAR_KIND" == maintain ]]; then
        # Every repo not yet printed, in order: what the finished ones
        # reported, the stopped ones as stopped; on a terminal the ones never
        # started too, so the block ends saying what became of each.
        for (( k = _PAR_DONE; k < _PAR_N; k++ )); do
            if (( _PAR_STATE[k] >= 1 )) && _res_read "$k"; then
                _maintain_text
                det="$VERBOSE"; (( _RES[3] || _RES[5] )) && det=1; [[ "$_TS" == FAILED ]] && det=1
                _par_emit "$k" "$_TS" "$_TN" "$det"
            elif (( _PAR_STATE[k] >= 1 )); then
                _par_emit "$k" stopped "by SIG${sig} — this repo may be mid-step; look at it with git status" 1
                names+=("${REPO_LIST[${_PAR_TG[$k]}]/#$HOME/\~}")
            elif (( _LIVE )); then
                _par_emit "$k" "not started" "" 0
            fi
        done
        _live_finish
        printf '\n' >&2
        warn "interrupted (SIG${sig}): ${#names[@]} repo(s) stopped mid-job${names[*]:+: ${names[*]}}; repos not started were not maintained."
    else
        _live_finish
        [[ "$_PAR_KIND" == status ]] || warn "interrupted (SIG${sig}) — nothing was deleted."
    fi
    exit "$code"
}

# _par_run JOBS IDX... — runs _PAR_KIND's job for the repos REPO_LIST[IDX],
# JOBS at a time, printing and counting each in order.
_par_run() {
    local jobs="$1" k; shift
    _PAR_TG=("$@"); _PAR_PID=(); _PAR_STATE=(); _PAR_N=$#; _PAR_DONE=0
    _PAR_T0=(); _PAR_PH=(); _PAR_LS=(); _PAR_LN=()
    _PAR_DIR="$(mktemp -d "${TMPDIR:-/tmp}/astromech.XXXXXX")" \
        || error_exit "cannot create a directory for each repo's output under ${TMPDIR:-/tmp}"
    for (( k = 0; k < _PAR_N; k++ )); do _PAR_STATE[k]=0; done
    _names_init "$@"
    if (( jobs > 1 )); then _par_parallel "$jobs"; else _par_sequential; fi
    _par_cleanup
}

# One at a time, in this process, as before item 238: a job of its own would
# have to give up the terminal, and with --jobs 1 a passphrase may still be
# typed. The output is buffered and printed exactly as the jobs' is; on a
# terminal the repo being worked on is one line, rewritten as it goes.
_par_sequential() {
    local k d="$_PAR_DIR"
    (( _LIVE )) && _LIVE_LINE=1
    for (( k = 0; k < _PAR_N; k++ )); do
        _PAR_STATE[k]=1; _PAR_T0[k]=$SECONDS; _PAR_CUR=$k
        (( _LIVE_LINE )) && _live_running "$k" ""
        _par_body "$k" >"${d}/${k}.out" 2>"${d}/${k}.err"
        _PAR_STATE[k]=2
        _par_flush "$k" 0
        _PAR_DONE=$(( k + 1 ))
    done
    _LIVE_LINE=0
    return 0
}

# Polled, not 'wait -n': that needs bash 4.3 and cannot say which job ended
# before 5.1.
_par_parallel() {
    local jobs="$1" n="$_PAR_N" k rc running=0 progress rcs=()
    trap '_par_abort INT' INT; trap '_par_abort TERM' TERM; trap '_par_abort HUP' HUP
    if (( _LIVE )); then _LIVE_BLOCK=1; _LIVE_HID=1; printf '\033[?25l' >&"$_LIVE_FD"; fi
    while (( _PAR_DONE < n )); do
        progress=0
        for (( k = _PAR_DONE; k < n; k++ )); do
            (( _PAR_STATE[k] == 1 )) || continue
            kill -0 "${_PAR_PID[k]}" 2>/dev/null && continue
            rc=0; wait "${_PAR_PID[k]}" || rc=$?
            _PAR_STATE[k]=2; rcs[k]=$rc; running=$(( running - 1 )); progress=1
            (( _LIVE_BLOCK )) && _par_cache "$k" "$rc"
        done
        for (( k = _PAR_DONE; k < n && running < jobs; k++ )); do
            (( _PAR_STATE[k] == 0 )) || continue
            [[ "$_PAR_KIND" == maintain ]] && _par_conflict "$k" && continue
            _par_spawn "$k"; running=$(( running + 1 )); progress=1
        done
        while (( _PAR_DONE < n )) && (( _PAR_STATE[_PAR_DONE] == 2 )); do
            _par_flush "$_PAR_DONE" "${rcs[_PAR_DONE]}"
            _PAR_DONE=$(( _PAR_DONE + 1 )); progress=1
        done
        (( _LIVE_BLOCK )) && _live_frame
        (( progress )) || sleep 0.1
    done
    _live_finish
    trap - INT TERM HUP
    return 0
}

# -----------------------------------------------------------------------------
# One line per repo (Kamino item 240)
# -----------------------------------------------------------------------------
#
# Not on a terminal (cron, a pipe, a front-end capturing it): each repo's line
# is printed once, when it and every repo before it are done, behind the log's
# timestamp - no escape sequences. On a terminal (stderr is one and TERM is not
# dumb) the lines being worked on are drawn live: with several jobs, a block of
# the repos not yet printed under the finished ones, redrawn in place with a
# spinner and the seconds each has been running; with --jobs 1, the one repo's
# line rewritten as its steps go (no ticking clock there: git may be asking
# for a passphrase on that very line). A repo's line is cut to the terminal's
# width, never wrapped - a wrapped line would throw the redraw off - and the
# block is never taller than the terminal, the rest summed up as "… N more".
# The summary below holds every skip and failure in full.

_LIVE=0; _LIVE_BLOCK=0; _LIVE_LINE=0; _LIVE_N=0; _LIVE_OPEN=0; _LIVE_HID=0
_LIVE_FD=2; _LIVE_COLS=80; _LIVE_ROWS=24; _LIVE_RESIZE=0; _LIVE_TICK=0; _LIVE_UTF=0
_LIVE_ELL="..."; _SPIN=('-' '\' '|' '/'); _SYM_Q="."; _SYM_OK="+"; _SYM_SK="-"; _SYM_F="x"; _SYM_X="!"
_SYM=""; _COL=""; _ROW=""; _FIT=""

_live_init() {
    _LIVE=0
    [[ -t 2 && -n "${TERM:-}" && "${TERM}" != dumb ]] || return 0
    _LIVE=1
    exec {_LIVE_FD}>&2
    # A multibyte character counts as one only in a UTF-8 locale; elsewhere
    # the symbols are ASCII and cutting a line cannot split one.
    local probe="→"
    if (( ${#probe} == 1 )); then
        _LIVE_UTF=1; _LIVE_ELL="…"; _SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
        _SYM_Q="·"; _SYM_OK="✓"; _SYM_SK="–"; _SYM_F="✗"; _SYM_X="!"
    fi
    _live_size
    trap '_LIVE_RESIZE=1' WINCH
    return 0
}

# The terminal's size: stty on stderr (the terminal being drawn on), else
# $COLUMNS/$LINES, else 80x24 - a pty nobody sized reports 0 0.
_live_size() {
    local s="" r="" c=""
    s="$(stty size <&2 2>/dev/null)" || s=""
    read -r r c <<<"$s" || true
    [[ "$c" =~ ^[0-9]+$ ]] && (( c > 0 )) || c="${COLUMNS:-80}"
    [[ "$r" =~ ^[0-9]+$ ]] && (( r > 0 )) || r="${LINES:-24}"
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    [[ "$r" =~ ^[0-9]+$ ]] || r=24
    _LIVE_COLS=$c; _LIVE_ROWS=$r; _LIVE_RESIZE=0
}

# _live_fit TEXT — TEXT cut to one column less than the terminal, into _FIT.
_live_fit() {
    local t="$1" max=$(( _LIVE_COLS - 1 ))
    (( max >= 1 )) || max=1
    if (( ${#t} > max )); then
        t="${t:0:max-1}"
        if (( ! _LIVE_UTF )); then
            # Bytes, here: never end on part of a character.
            while [[ "$t" == *[$'\x80'-$'\xff'] ]]; do t="${t%?}"; done
        fi
        t+="$_LIVE_ELL"
    fi
    _FIT="$t"
}

_state_style() {
    case "$1" in
        ok|planned)     _SYM="$_SYM_OK"; _COL="$C_G" ;;
        skipped)        _SYM="$_SYM_SK"; _COL="$C_Y" ;;
        FAILED|refused) _SYM="$_SYM_F";  _COL="$C_R" ;;
        stopped)        _SYM="$_SYM_X";  _COL="$C_R" ;;
        *)              _SYM="$_SYM_Q";  _COL="" ;;
    esac
}

# _names_init IDX... — each repo's name on its line: its path under its root,
# or under ~ when the repos come from more than one root.
_names_init() {
    local i r="" one=1 nm
    _NAME=(); _NAMEW=0
    for i in "$@"; do
        [[ -n "$r" ]] || r="${REPO_ROOT[$i]}"
        [[ "${REPO_ROOT[$i]}" == "$r" ]] || one=0
    done
    for i in "$@"; do
        if (( one )); then
            nm="${REPO_LIST[$i]#"${REPO_ROOT[$i]}"/}"
            [[ "${REPO_LIST[$i]}" == "${REPO_ROOT[$i]}" ]] && nm="."
        else
            nm="${REPO_LIST[$i]/#$HOME/\~}"
        fi
        _NAME[i]="$nm"
        (( ${#nm} <= _NAMEW )) || _NAMEW=${#nm}
    done
    (( _NAMEW <= 40 )) || _NAMEW=40
    return 0
}

# _row I STATE NOTE SYMBOL COLOUR FIT — repo I's line, into _ROW. Elsewhere
# than a terminal, "<timestamp> name  state: note"; on one, "  S name  state:
# note" with the symbol and the state coloured, cut to the width when FIT.
_row() {
    local nm="${_NAME[$1]}" st="$2" note="$3" sym="$4" col="$5" pre t off
    printf -v pre '%-*s' "$_NAMEW" "$nm"
    t="${pre}  ${st}${note:+: ${note}}"
    if (( ! _LIVE )); then _ROW="$(_pfx)${t}"; return 0; fi
    t="  ${sym} ${t}"
    if (( $6 )); then _live_fit "$t"; t="$_FIT"; fi
    off=$(( 4 + ${#pre} + 2 ))
    _ROW="${t:0:2}${col}${t:2:1}${C_N}${t:3:$(( off - 3 ))}${col}${t:off:${#st}}${C_N}${t:$(( off + ${#st} ))}"
}

# _live_running K [PHASE] — --jobs 1 on a terminal: repo K's line, in place.
_live_running() {
    local k="$1"
    (( _LIVE_RESIZE )) && _live_size
    if [[ -n "${2:-}" ]]; then _PAR_PH[k]="$2"; fi
    _row "${_PAR_TG[$k]}" "${_PAR_PH[k]:-$_PH0}${_LIVE_ELL}" "" "${_SPIN[0]}" "$C_C" 1
    printf '\r\033[2K%s' "$_ROW" >&"$_LIVE_FD"
    _LIVE_OPEN=1
}

# _live_row K — job K's line in the block, into _ROW.
_live_row() {
    local k="$1" ph=""
    case "${_PAR_STATE[k]}" in
        0) _row "${_PAR_TG[$k]}" queued "" "$_SYM_Q" "" 1 ;;
        1)
            if [[ -f "${_PAR_DIR}/${k}.phase" ]]; then IFS= read -r ph < "${_PAR_DIR}/${k}.phase" || true; fi
            [[ -z "$ph" ]] || _PAR_PH[k]="$ph"
            _row "${_PAR_TG[$k]}" "${_PAR_PH[k]:-$_PH0}${_LIVE_ELL} $(( SECONDS - _PAR_T0[k] ))s" "" \
                "${_SPIN[_LIVE_TICK % ${#_SPIN[@]}]}" "$C_C" 1 ;;
        *)
            _state_style "${_PAR_LS[k]:-}"
            _row "${_PAR_TG[$k]}" "${_PAR_LS[k]:-}" "${_PAR_LN[k]:-}" "$_SYM" "$_COL" 1 ;;
    esac
}

# _live_frame — redraws the block (every repo not yet printed) in place.
_live_frame() {
    local k n="$_PAR_N" cap shown=0 out=""
    (( _LIVE_RESIZE )) && _live_size
    _LIVE_TICK=$(( _LIVE_TICK + 1 ))
    (( _LIVE_N == 0 )) || out+=$'\033['"${_LIVE_N}"'A'
    out+=$'\r'
    cap=$(( _LIVE_ROWS - 2 )); (( cap >= 1 )) || cap=1
    for (( k = _PAR_DONE; k < n; k++ )); do
        if (( n - _PAR_DONE > cap && shown == cap - 1 )); then
            _live_fit "  ${_LIVE_ELL} $(( n - k )) more"
            out+=$'\033[2K'"$_FIT"$'\n'; shown=$(( shown + 1 ))
            break
        fi
        _live_row "$k"
        out+=$'\033[2K'"$_ROW"$'\n'; shown=$(( shown + 1 ))
    done
    out+=$'\033[J'
    printf '%s' "$out" >&"$_LIVE_FD"
    _LIVE_N=$shown
}

# _live_clear — removes the block; the cursor is left where it began.
_live_clear() {
    (( _LIVE_N == 0 )) || printf '\033[%dA' "$_LIVE_N" >&"$_LIVE_FD"
    printf '\r\033[J' >&"$_LIVE_FD"
    _LIVE_N=0
}

# _live_finish — the block is done with: cleared, the cursor shown again.
_live_finish() {
    if (( _LIVE_BLOCK )); then _live_clear; _LIVE_BLOCK=0; fi
    if (( _LIVE_HID )); then printf '\033[?25h' >&"$_LIVE_FD"; _LIVE_HID=0; fi
    return 0
}

# _live_restore — on exit, whatever way it comes: a line left open (--jobs 1
# stopped mid-repo) is closed saying so, the cursor is shown.
_live_restore() {
    (( _LIVE )) || return 0
    if (( _LIVE_OPEN )); then
        if (( _LIVE_LINE )) && [[ "$_PAR_KIND" == maintain ]]; then
            _state_style stopped
            _row "${_PAR_TG[$_PAR_CUR]}" stopped "interrupted — this repo may be mid-step; look at it with git status" "$_SYM" "$_COL" 1
            printf '\r\033[2K%s\n' "$_ROW" >&"$_LIVE_FD"
        elif (( _LIVE_LINE )); then
            printf '\r\033[2K' >&"$_LIVE_FD"
        else
            printf '\n' >&"$_LIVE_FD"
        fi
        _LIVE_OPEN=0
    fi
    _live_finish
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

# Branch names tidy never plans, whatever they contain (Kamino item 140). Only
# the detected trunk was excluded, so in a git-flow repository (origin/HEAD ->
# develop) a local main behind develop counted as merged and `tidy --yes`
# deleted it, its upstream setting with it; release/* or stable likewise.
# Long-lived by convention, and the README promises trunks never appear.
# maintain reads the same list: it never wip-commits on one (Kamino item 170).
TIDY_KEEP=(main master develop development trunk stable 'release/*' 'hotfix/*')
_tidy_keep() {
    local p
    for p in "${TIDY_KEEP[@]}"; do
        # shellcheck disable=SC2053
        [[ "$1" == $p ]] && return 0
    done
    return 1
}

# _busy_branches REPO - every branch some worktree of REPO is using: checked
# out, or being rebased or bisected (git then shows the worktree as detached,
# so %(worktreepath) is empty for the branch and git refuses to delete it -
# a spurious REFUSED with -D advice; Kamino item 142). The first worktree git
# lists is the main one, REPO itself, whose git dir discovery already knows.
_busy_branches() {
    local repo="$1" line wt gd f first=1
    while IFS= read -r line; do
        case "$line" in
            "branch refs/heads/"*) printf '%s\n' "${line#branch refs/heads/}" ;;
            "worktree "*)
                wt="${line#worktree }"
                if (( first )) && [[ -n "${RGD[$repo]-}" ]]; then gd="${RGD[$repo]}"
                else gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { first=0; continue; }; fi
                first=0
                for f in rebase-merge/head-name rebase-apply/head-name; do
                    [[ -f "${gd}/${f}" ]] && sed 's#^refs/heads/##' "${gd}/${f}"
                done
                [[ -f "${gd}/BISECT_START" ]] && head -1 "${gd}/BISECT_START"
                ;;
        esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
}

TIDY_PLAN=()        # "<repo>\t<branch>\t<base>\t<short sha>", in discovery order
TIDY_NOTES=()       # repos that could not be planned, and why
TIDY_DELETED=0; TIDY_FAILED=0; TIDY_LINES=()
TIDY_DONE=(); TIDY_REFUSED=()   # the last _tidy_apply's: "<branch> (was <sha>)", "<branch>"

# _tidy_plan_repo <repo> — appends one TIDY_PLAN entry per local branch of
# <repo> that is already contained in its trunk. Reads only: one for-each-ref
# for the common case (a snapshot status has just taken is reused), plus the
# worktree list and one for-each-ref --merged when some branch is a candidate
# (Kamino item 239: it was a merge-base per branch, a rev-parse per sha).
_tidy_plan_repo() {
    local repo="$1" op trunk base b n=0 cands=()

    if [[ "$(_work_tree "$repo")" != true ]]; then
        TIDY_NOTES+=("${repo}: not a git work tree"); return 0
    fi
    op="$(_in_progress "$repo")"
    [[ -n "$op" ]] && { TIDY_NOTES+=("${repo}: ${op} in progress — left alone"); return 0; }
    [[ "$S_REPO" == "$repo" ]] || _snap "$repo"
    # As the README says, and as maintain does (Kamino item 142).
    (( S_HASBR )) || { TIDY_NOTES+=("${repo}: detached HEAD — left alone"); return 0; }
    trunk="$(_default_branch "$repo")" || { TIDY_NOTES+=("${repo}: no main or master branch"); return 0; }

    if _has_ref "refs/remotes/origin/${trunk}"; then
        base="origin/${trunk}"
    elif _has_ref "refs/heads/${trunk}"; then
        # No remote at all (or never fetched): the local trunk is the only
        # answer there is. Said out loud, because it is the weaker one.
        base="$trunk"
        TIDY_NOTES+=("${repo}: no origin/${trunk} — measured against the local ${trunk} instead")
    else
        TIDY_NOTES+=("${repo}: '${trunk}' exists neither locally nor on origin"); return 0
    fi

    # The branch names come from refname, not :short - a branch sharing its
    # name with a tag comes out of :short as heads/<name>, and dropped out of
    # the plan (Kamino item 142).
    for b in "${S_HEADS[@]}"; do
        [[ "$b" == "$trunk" ]] && continue
        _tidy_keep "$b" && continue
        # A branch checked out anywhere — here or in another worktree — has a
        # worktreepath, and git refuses to delete it. It must not appear in a
        # list that says it will be deleted.
        [[ -n "${S_WTP[$b]}" ]] && continue
        cands+=("$b")
    done
    if (( ${#cands[@]} )); then
        local -A busy=() merged=()
        while IFS= read -r b; do [[ -n "$b" ]] && busy[$b]=1; done < <(_busy_branches "$repo")
        # Contained in the base: exactly merge-base --is-ancestor, for every
        # branch in one call.
        while IFS= read -r b; do [[ -n "$b" ]] && merged[${b#refs/heads/}]=1; done \
            < <(git -C "$repo" for-each-ref --merged "$base" --format='%(refname)' refs/heads/ 2>/dev/null)
        for b in "${cands[@]}"; do
            [[ -n "${busy[$b]:-}" ]] && continue
            [[ -n "${merged[$b]:-}" ]] || continue
            TIDY_PLAN+=("${repo}"$'\t'"${b}"$'\t'"${base}"$'\t'"${S_REF[refs/heads/$b]:-?}")
            n=$(( n + 1 ))
        done
    fi
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
            IFS=$'\t' read -r repo b base sha <<< "$p"
            if [[ "$repo" != "$cur" ]]; then
                (( repos )) && printf '\n'
                cur="$repo"; repos=$(( repos + 1 ))
                printf '  %s  (merged into %s)\n' "${repo/#$HOME/\~}" "$base"
            fi
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

# _tidy_apply — deletes everything in TIDY_PLAN, one branch at a time. The sha
# is read again here, not taken from the plan: it is the recovery handle, and
# the branch may have moved while the question was open.
_tidy_apply() {
    local p repo b base sha
    TIDY_DONE=(); TIDY_REFUSED=()
    for p in "${TIDY_PLAN[@]}"; do
        IFS=$'\t' read -r repo b base _ <<< "$p"
        sha="$(git -C "$repo" rev-parse --short "refs/heads/${b}" 2>/dev/null || echo '?')"
        if _git "$repo" branch -d "$b"; then
            TIDY_DELETED=$(( TIDY_DELETED + 1 ))
            TIDY_DONE+=("${b} (was ${sha})")
            info "deleted ${b} (was ${sha}) in ${repo/#$HOME/\~}"
        else
            # git's -d test is narrower than this plan's: it asks whether the
            # branch is contained in HEAD or in its own upstream, so a local
            # trunk sitting behind origin's can make it refuse a branch that
            # origin's trunk demonstrably holds. Reported, never forced — -D
            # is the operator's call, and the sha above is enough to recover
            # either way.
            TIDY_FAILED=$(( TIDY_FAILED + 1 ))
            TIDY_REFUSED+=("$b")
            TIDY_LINES+=("REFUSED  ${repo/#$HOME/\~}: ${b} (${sha}) — git -C ${repo/#$HOME/\~} branch -D ${b}  # contained in ${base}")
        fi
    done
}

cmd_tidy() {
    _run_lock || error_exit "another ${SCRIPT_NAME} run is in progress (lock: $(_lock_path)). Wait for it, or remove the lock if you are sure it is dead."
    trap '_on_exit' EXIT
    load_config
    (( ${#ROOTS[@]} )) || error_exit "No roots configured. Add one: ${SCRIPT_NAME}.sh add-root PATH"
    discover
    _select_targets
    (( ${#TARGETS[@]} )) || { warn "No repositories found under the configured roots."; return 0; }

    # Nothing is fetched here, on purpose: tidy must not reach the network to
    # decide what to delete. It therefore measures against whatever origin/
    # trunk was last fetched, which usually means FEWER branches seen as
    # merged - but not always: after the trunk was force-pushed, the last
    # fetched origin/trunk may hold commits the remote no longer has (Kamino
    # item 142). 'maintain --tidy' pulls first and measures against the
    # current one.
    #
    # Planned with the job runner, --jobs at a time (Kamino item 241); the
    # plan is gathered in repo order, so it reads as it did one by one. On a
    # terminal the repos being planned are drawn live and the block is
    # cleared once the plan is printed in its place; elsewhere planning
    # prints nothing of its own - the plan is its record.
    TIDY_PLAN=(); TIDY_NOTES=()
    local jobs; jobs="$(_jobs)"
    (( jobs <= ${#TARGETS[@]} )) || jobs=${#TARGETS[@]}
    _live_init
    _PAR_KIND=plan _PH0=planning
    _par_run "$jobs" "${TARGETS[@]}"

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
    # One line per repo with something to delete, one repo at a time: local
    # `git branch -d`s, nothing to gain from more.
    local i p dels=()
    for i in "${TARGETS[@]}"; do
        for p in "${TIDY_PLAN[@]}"; do
            [[ "$p" == "${REPO_LIST[$i]}"$'\t'* ]] && { dels+=("$i"); break; }
        done
    done
    _PAR_KIND=delete _PH0=deleting
    _par_run 1 "${dels[@]}"
    printf '\n' >&2
    info "Summary: ${TIDY_DELETED} deleted, ${TIDY_FAILED} refused."
    if (( ${#TIDY_LINES[@]} )); then
        local l
        for l in "${TIDY_LINES[@]}"; do printf '          %s\n' "$l" >&2; done
    fi
    (( TIDY_FAILED == 0 ))
}

# _plan_body K — plans _PAR_TG[K]: its result is the count of plan entries,
# the count of notes, then both.
_plan_body() {
    local k="$1" i="${_PAR_TG[$1]}"
    local TIDY_PLAN=() TIDY_NOTES=()
    _tidy_plan_repo "${REPO_LIST[$i]}"
    _par_result "$k" "${#TIDY_PLAN[@]}" "${#TIDY_NOTES[@]}" "${TIDY_PLAN[@]}" "${TIDY_NOTES[@]}"
}

_flush_plan() {
    local k="$1" rc="$2" i="${_PAR_TG[$1]}" np nn
    if _res_read "$k"; then
        np="${_RES[0]}"; nn="${_RES[1]}"
        (( np == 0 )) || TIDY_PLAN+=("${_RES[@]:2:np}")
        (( nn == 0 )) || TIDY_NOTES+=("${_RES[@]:2+np:nn}")
    else
        TIDY_NOTES+=("${REPO_LIST[$i]}: could not be planned (exit ${rc}) — left alone")
    fi
    if (( _LIVE_OPEN )); then printf '\r\033[2K' >&"$_LIVE_FD"; _LIVE_OPEN=0; fi
    if (( VERBOSE )) && [[ -s "${_PAR_DIR}/${k}.err" ]]; then cat "${_PAR_DIR}/${k}.err" >&2; fi
    return 0
}

# _delete_body K — deletes what the plan holds for _PAR_TG[K]: its result is
# the deleted and refused counts, then tidy's REFUSED lines, the branches
# deleted ("name (was sha)") and the ones refused, each list after its count.
_delete_body() {
    local k="$1" i="${_PAR_TG[$1]}" p mine=()
    for p in "${TIDY_PLAN[@]}"; do [[ "$p" == "${REPO_LIST[$i]}"$'\t'* ]] && mine+=("$p"); done
    local TIDY_PLAN=("${mine[@]}") TIDY_DELETED=0 TIDY_FAILED=0 TIDY_LINES=() TIDY_DONE=() TIDY_REFUSED=()
    _tidy_apply
    _par_result "$k" "$TIDY_DELETED" "$TIDY_FAILED" "${#TIDY_LINES[@]}" "${#TIDY_DONE[@]}" \
        "${TIDY_LINES[@]}" "${TIDY_DONE[@]}" "${TIDY_REFUSED[@]}"
}

_flush_delete() {
    local k="$1" rc="$2" nl nd details="$VERBOSE" dl=() refused=() x
    if _res_read "$k"; then
        TIDY_DELETED=$(( TIDY_DELETED + _RES[0] )); TIDY_FAILED=$(( TIDY_FAILED + _RES[1] ))
        nl="${_RES[2]}"; nd="${_RES[3]}"
        (( nl == 0 )) || TIDY_LINES+=("${_RES[@]:4:nl}")
        (( nd == 0 )) || dl=("${_RES[@]:4+nl:nd}")
        (( ${#_RES[@]} <= 4 + nl + nd )) || refused=("${_RES[@]:4+nl+nd}")
        _TN=""
        for x in "${dl[@]}"; do _TN+="${_TN:+, }${x}"; done
        [[ -z "$_TN" ]] || _TN="deleted ${_TN}"
        if (( ${#refused[@]} )); then
            _TS=refused; details=1
            local r=""
            for x in "${refused[@]}"; do r+="${r:+, }${x}"; done
            _TN="${r}${_TN:+; ${_TN}}"
        else
            _TS=ok
        fi
    else
        _TS=FAILED; _TN="stopped unexpectedly (exit ${rc})"; details=1
    fi
    _par_emit "$k" "$_TS" "$_TN" "$details"
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

# --includes: a value set in a file the global config includes is the one git
# uses, and was reported as unset (Kamino item 142).
_prune_global() { git config --global --includes --get fetch.prune 2>/dev/null || true; }
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
            cur="$(_prune_global || true)"
            printf 'fetch.prune=%s\n' "${cur:-unset}"
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
        for i in "${IGNORES[@]}"; do _ignore_in "$i" "$root" || keep_i+=("$i"); done
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
    for i in "${IGNORES[@]}"; do _ignore_in "$i" "$root" || keep+=("$i"); done
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
    printf 'jobs=%d\n' "$(_jobs)"
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
    # Read-only: no optional locks, so status cannot fail a concurrent cron
    # maintain on index.lock (Kamino item 142).
    export GIT_OPTIONAL_LOCKS=0
    load_config
    (( ${#ROOTS[@]} )) || { echo "(no roots configured)"; return 0; }
    discover
    # Each repo's rows are made by the job runner, --jobs at a time (Kamino
    # item 239), then the tree is printed in order from them.
    local all=("${!REPO_LIST[@]}") jobs
    SR_E=(); SR_K=(); SR_NS=(); SR_NP=(); SR_LB=()
    if (( ${#all[@]} )); then
        jobs="$(_jobs)"; (( jobs <= ${#all[@]} )) || jobs=${#all[@]}
        trap '_on_exit' EXIT
        _PAR_KIND=status _PH0=reading
        _par_run "$jobs" "${all[@]}"
    fi
    local root i entries=() kids=() n k last cont line idx any_stash=0
    local total=0 repos_with=0 any_local_base=0
    for root in "${ROOTS[@]}"; do
        printf '%s\n' "${root/#$HOME/\~}"
        if [[ ! -d "$root" ]]; then echo "└── (folder not found)"; echo; continue; fi
        entries=(); kids=()
        for i in "${!REPO_LIST[@]}"; do
            [[ "${REPO_ROOT[$i]}" == "$root" ]] || continue
            entries+=("${SR_E[i]}")
            idx=$(( ${#entries[@]} - 1 ))
            (( SR_NS[i] )) && any_stash=1
            if (( SR_NP[i] )); then
                repos_with=$(( repos_with + 1 )); total=$(( total + SR_NP[i] ))
                (( SR_LB[i] )) && any_local_base=1
                kids[idx]="${SR_K[i]}"
            fi
        done
        for i in "${IGNORES[@]}"; do
            _ignore_in "$i" "$root" && entries+=("${i#"${root}"/}/  (ignored)")
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
    (( any_stash )) && echo "[branch, N stashed] = N changes astromech stashed and nobody has picked up (git stash list)"
    if (( total )); then
        printf -- '- branch   = already contained in the trunk on origin; %s.sh tidy deletes these\n' "$SCRIPT_NAME"
        (( any_local_base )) && printf -- '             (where a repo has no origin, against its local trunk instead)\n'
        printf -- '%d branch(es) in %d repo(s) can be tidied.\n' "$total" "$repos_with"
    fi
}

SR_E=(); SR_K=(); SR_NS=(); SR_NP=(); SR_LB=()   # status's rows, by repo index

# _status_rel I — repo I's path under its root, as the tree shows it.
_status_rel() {
    local i="$1" rel
    rel="${REPO_LIST[$i]#"${REPO_ROOT[$i]}"/}"; [[ "${REPO_LIST[$i]}" == "${REPO_ROOT[$i]}" ]] && rel="."
    printf '%s' "$rel"
}

# _status_body K — repo _PAR_TG[K]'s rows: its entry (relative path, branch,
# dirty, stashes), the local branches tidy would delete, and what the legend
# needs to know. The tidy-able branches come from _tidy_plan_repo — the very
# function tidy plans with — rather than a second, similar-looking query here.
# Two implementations of "already merged" would eventually disagree, and
# status promising a deletion tidy then refuses (or hiding one it would make)
# is worse than not showing them at all.
#
# Three git calls in the common case: discovery's rev-parse, then status and
# for-each-ref here, which the plan reuses (it was fifteen; Kamino item 239).
_status_body() {
    local k="$1" i="${_PAR_TG[$1]}" repo br ns=0 entry p pbr pbase psha note kids="" lb=0
    local TIDY_PLAN=() TIDY_NOTES=()
    repo="${REPO_LIST[$i]}"
    _snap "$repo" status
    if (( S_HASBR )); then br="$S_BR"
    else
        # A rebase detaches HEAD; say which (Kamino item 142).
        br="$(_in_progress "$repo")"; br="(${br:-detached})"
    fi
    (( S_DIRTY )) && br+=" *"
    _has_ref refs/stash && ns="$(_stashes "$repo")"
    (( ns )) && br+=", ${ns} stashed"
    printf -v entry '%-40s %s' "$(_status_rel "$i")" "[${br}]"

    # Costs nothing in the common case: a repo whose only branch is its
    # trunk plans no work, and the loop below never runs.
    _tidy_plan_repo "$repo"
    for p in "${TIDY_PLAN[@]}"; do
        IFS=$'\t' read -r _ pbr pbase psha <<<"$p"
        # A base that is not on origin is a weaker claim — the work is only
        # known to be on this machine — so it is labelled rather than
        # silently mixed in with the rest.
        note=""
        if [[ "$pbase" != origin/* ]]; then
            note="  (vs the local ${pbase} — no origin)"; lb=1
        fi
        kids+="$(printf -- '- %-38s %s%s' "$pbr" "$psha" "$note")"$'\n'
    done
    _par_result "$k" "$entry" "${kids%$'\n'}" "$ns" "${#TIDY_PLAN[@]}" "$lb"
}

_flush_status() {
    local k="$1" rc="$2" i="${_PAR_TG[$1]}"
    if _res_read "$k"; then
        SR_E[i]="${_RES[0]}"; SR_K[i]="${_RES[1]}"; SR_NS[i]="${_RES[2]}"; SR_NP[i]="${_RES[3]}"; SR_LB[i]="${_RES[4]}"
    else
        printf -v 'SR_E[i]' '%-40s %s' "$(_status_rel "$i")" "[could not be read (exit ${rc})]"
        SR_K[i]=""; SR_NS[i]=0; SR_NP[i]=0; SR_LB[i]=0
    fi
    if (( VERBOSE )) && [[ -s "${_PAR_DIR}/${k}.err" ]]; then cat "${_PAR_DIR}/${k}.err" >&2; fi
    return 0
}

# -----------------------------------------------------------------------------
# %(worktreepath) arrived in git 2.23; older ones print an empty field, and
# tidy would then plan checked-out branches without a word (Kamino item 142).
_require_git() {
    local v maj min
    v="$(git version 2>/dev/null | awk '{print $3}')"
    maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 0
    (( maj > 2 || (maj == 2 && min >= 23) )) || error_exit "git ${v} is too old: ${SCRIPT_NAME} needs 2.23 or newer."
}

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
            --jobs)       [[ $# -ge 2 ]] || error_exit "--jobs needs a number"; JOBS="$2"; shift 2 ;;
            --jobs=*)     JOBS="${1#*=}"; shift ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; args+=("$@"); break ;;
            -*)           error_exit "unknown flag: $1 (see --help)" ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    [[ -z "$JOBS" ]] || _jobs_valid "$JOBS" || error_exit "--jobs: expected a number from 1 to ${JOBS_MAX}, got '${JOBS}'"
    case "$cmd" in maintain|tidy|status|repos|prune) _require_git ;; esac
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
