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
# No prompts: everything is driven by commands and flags, so it drops into a
# cron job, a systemd timer or a TUI alike. The interactive experience lives in
# a separate front-end (scomp-link) that drives this engine with flags — the
# holo-convert / holonet-sync pattern.
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
VERSION="1.0.0"

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
  --repo PATH              maintain: limit to one discovered repo
  --dry-run                maintain: report what would happen, change nothing
  -v, --verbose            debug logging
  -h, --help

Per repo, maintain does:
  feature branch  -> git add -A; git commit (auto message); git checkout main|master
  main|master     -> if dirty: git stash push -u (the stash is left for you)
  then            -> git pull --rebase
Nothing is pushed. A failed step leaves the repo as that step left it (a stopped
rebase stays stopped for you to resolve) and the run moves on. Repos mid-rebase/
merge, on a detached HEAD, or with neither main nor master are skipped.
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
_default_branch() {
    local b
    for b in main master; do
        if git -C "$1" show-ref --verify -q "refs/heads/${b}" \
            || git -C "$1" show-ref --verify -q "refs/remotes/origin/${b}"; then
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

cmd_maintain() {
    # Taken before discovery so two runs cannot both walk the roots and then
    # both start writing.
    _run_lock || error_exit "another ${SCRIPT_NAME} maintenance run is in progress (lock: $(_lock_path)). Wait for it, or remove the lock if you are sure it is dead."
    trap '_release_lock' EXIT
    load_config
    (( ${#ROOTS[@]} )) || error_exit "No roots configured. Add one: ${SCRIPT_NAME}.sh add-root PATH"
    discover

    local targets=() i
    if [[ -n "$ONLY_REPO" ]]; then
        local want; want="$(_abspath "$ONLY_REPO")" || error_exit "--repo: not a directory: ${ONLY_REPO}"
        for i in "${!REPO_LIST[@]}"; do [[ "${REPO_LIST[$i]}" == "$want" ]] && targets+=("$i"); done
        (( ${#targets[@]} )) || error_exit "--repo: ${want} is not a discovered repo (see: ${SCRIPT_NAME}.sh repos)"
    else
        targets=("${!REPO_LIST[@]}")
    fi
    (( ${#targets[@]} )) || { warn "No repositories found under the configured roots."; return 0; }

    (( DRY_RUN )) && info "Dry run — nothing will be changed."
    info "Maintaining ${#targets[@]} repo(s)…"

    local n_ok=0 n_skip=0 n_fail=0 rel lines=()
    for i in "${targets[@]}"; do
        rel="${REPO_LIST[$i]#"${REPO_ROOT[$i]}"/}"
        [[ "${REPO_LIST[$i]}" == "${REPO_ROOT[$i]}" ]] && rel="."
        printf '\n%s%s── %s%s  %s\n' "$(_pfx)" "$C_B" "$rel" "$C_N" "(${REPO_ROOT[$i]/#$HOME/\~})" >&2
        maintain_repo "${REPO_LIST[$i]}"
        case "$R_STATUS" in
            ok)      n_ok=$((n_ok + 1)) ;;
            skipped) n_skip=$((n_skip + 1));  lines+=("skipped  ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
            failed)  n_fail=$((n_fail + 1));  lines+=("FAILED   ${REPO_LIST[$i]/#$HOME/\~}: ${R_NOTE}") ;;
        esac
    done

    printf '\n' >&2
    info "Summary: ${n_ok} ok, ${n_skip} skipped, ${n_fail} failed."
    local l
    for l in "${lines[@]}"; do printf '          %s\n' "$l" >&2; done
    (( n_fail == 0 ))
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

# Plain tree on stdout: per root, its repos (relative path, branch, dirty) and
# its ignored folders.
cmd_status() {
    load_config
    (( ${#ROOTS[@]} )) || { echo "(no roots configured)"; return 0; }
    discover
    local root i entries=() rel br n k last
    for root in "${ROOTS[@]}"; do
        printf '%s\n' "${root/#$HOME/\~}"
        if [[ ! -d "$root" ]]; then echo "└── (folder not found)"; echo; continue; fi
        entries=()
        for i in "${!REPO_LIST[@]}"; do
            [[ "${REPO_ROOT[$i]}" == "$root" ]] || continue
            rel="${REPO_LIST[$i]#"${root}"/}"; [[ "${REPO_LIST[$i]}" == "$root" ]] && rel="."
            br="$(_current_branch "${REPO_LIST[$i]}")" || br="(detached)"
            _is_dirty "${REPO_LIST[$i]}" && br+=" *"
            entries+=("$(printf '%-40s %s' "$rel" "[${br}]")")
        done
        for i in "${IGNORES[@]}"; do
            [[ "$i" == "${root}/"* ]] && entries+=("${i#"${root}"/}/  (ignored)")
        done
        n=${#entries[@]}
        (( n )) || { echo "└── (no repositories found)"; echo; continue; }
        for k in "${!entries[@]}"; do
            last=$(( k == n - 1 ))
            printf '%s %s\n' "$( (( last )) && echo '└──' || echo '├──')" "${entries[$k]}"
        done
        echo
    done
    echo "[branch *] = uncommitted changes"
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
            -v|--verbose) VERBOSE=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; args+=("$@"); break ;;
            -*)           error_exit "unknown flag: $1 (see --help)" ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    case "$cmd" in
        maintain)       cmd_maintain ;;
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
