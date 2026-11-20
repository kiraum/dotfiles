#!/bin/bash
#
# Start-of-day work environment bootstrap.
#
# Configuration lives in .env; see WORK_ENV_FILE below.
#
# .env keys:
#   VMS               newline-separated "<ip-or-host>[_<label>]" entries, one window each
#   SSH_USERNAME      user for ssh connections (optional; defaults to local $USER)
#   DEV_DIR           starting directory for the dev window (default $GIT_TREE)
#   BASTION_HOST      agent-forwarded jump host; logged into before tmux starts
#   SSH_KEYS          space-separated private keys to ssh-add (optional)
#   PANES_PER_HOST    panes per host window (default 2)
#   AUTORUN_SSH       "true" runs ssh immediately, "false" only types it (default true)
#   YUBISWITCH        "true" enables the YubiKey via yubiswitch before logging in

set -uo pipefail

readonly WORK_DIR="${WORK_DIR:-$HOME/Documents/work}"
readonly GIT_TREE="${GIT_TREE:-$WORK_DIR/git_tree}"
# Matches the pipe-pane binding in .tmux.conf; keep the two in sync.
readonly LOG_DIR="${LOG_DIR:-$WORK_DIR/logs}"
readonly ARCHIVE_DIR="$LOG_DIR/archived"
readonly SESSION="${SESSION:-work}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

# Resolve the .env next to the real script, not the cwd, since this is normally
# invoked via the ~/init_work.sh symlink from an arbitrary directory.
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
	link_target=$(readlink "$script_path")
	case $link_target in
	/*) script_path=$link_target ;;
	*) script_path="$(dirname "$script_path")/$link_target" ;;
	esac
done
SCRIPT_DIR="$(cd "$(dirname "$script_path")" && pwd)"
readonly SCRIPT_DIR

env_file="${WORK_ENV_FILE:-}"
if [ -z "$env_file" ]; then
	for candidate in "$SCRIPT_DIR/.env" "$HOME/.env" "$WORK_DIR/.env"; do
		[ -f "$candidate" ] && env_file=$candidate && break
	done
fi

[ -n "$env_file" ] || die "no .env found (looked in $SCRIPT_DIR, $HOME, $WORK_DIR)"
[ -f "$env_file" ] || die ".env file not found: $env_file"

log "loading config from $env_file"
set -o allexport
# shellcheck source=/dev/null
source "$env_file"
set +o allexport

: "${VMS:=}"
: "${SSH_USERNAME:=$USER}"
: "${DEV_DIR:=$GIT_TREE}"
: "${BASTION_HOST:=}"
: "${SSH_KEYS:=}"
: "${PANES_PER_HOST:=2}"
: "${AUTORUN_SSH:=true}"
: "${YUBISWITCH:=false}"

command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"

if [ -n "${TMUX:-}" ]; then
	die "already inside tmux; detach first (this script recreates the '$SESSION' session)"
fi

DATE="$(date +%s)"
readonly DATE

# ----------------------------------------------------------------------------
# ssh-agent and certificates
# ----------------------------------------------------------------------------

# Always start from a clean agent and always log in again. Re-running this
# script is how you recover from a stale or broken certificate, so it must
# never decide the existing one is good enough and skip.

reset_ssh_agent() {
	pkill -9 ssh-agent >/dev/null 2>&1
	unset SSH_AUTH_SOCK SSH_AGENT_PID
	eval "$(ssh-agent -s)" >/dev/null
	log "started a fresh ssh-agent (pid ${SSH_AGENT_PID:-unknown})"

	[ -n "$SSH_KEYS" ] || return
	# shellcheck disable=SC2086 # intentional word splitting: space-separated list
	for key in $SSH_KEYS; do
		key="${key/#\~/$HOME}"
		[ -f "$key" ] || {
			warn "ssh key not found: $key"
			continue
		}
		ssh-add "$key" || warn "could not add key: $key"
	done
}

# The agent-forwarded bastion login mints the certificates every other host
# authenticates with. It runs on the real terminal, before tmux takes over, so
# the password and 2FA prompts are visible. Without it every connection falls
# back to repeated password prompts.
bastion_login() {
	if [ -z "$BASTION_HOST" ]; then
		warn "BASTION_HOST is unset; skipping certificate login"
		return
	fi

	# Without a tty ssh cannot prompt for the password or 2FA token.
	if [ ! -t 0 ]; then
		warn "not running on a terminal; skipping login to $BASTION_HOST"
		return
	fi

	if [ "$YUBISWITCH" = "true" ]; then
		osascript -e 'tell application "yubiswitch" to KeyOn' >/dev/null 2>&1 ||
			warn "could not enable YubiKey via yubiswitch"
	fi

	log "logging in to $BASTION_HOST to load your certificates"
	log "enter your password and 2FA token; the session closes itself once done"

	# The bastion hangs up after issuing the certificates, so ssh reports a
	# non-zero status on a perfectly successful login. Count what landed in the
	# agent instead of trusting the exit code.
	ssh -A "$BASTION_HOST"

	local certs
	certs=$(ssh-add -L 2>/dev/null | grep -c -- '-cert-v[0-9][0-9]*@openssh.com')
	if [ "$certs" -gt 0 ]; then
		log "$certs certificate(s) loaded"
	else
		warn "no certificates in the agent; connections will prompt for a password"
	fi
}

reset_ssh_agent
bastion_login

# ----------------------------------------------------------------------------
# Logs
# ----------------------------------------------------------------------------

mkdir -p "$ARCHIVE_DIR" || die "could not create $ARCHIVE_DIR"

# Move only log files; a plain `mv $LOG_DIR/*` would try to move archived/ into
# itself and abort the rotation partway through.
archive_logs() {
	find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -exec mv {} "$ARCHIVE_DIR"/ \; 2>/dev/null
}

log "archiving previous logs"
archive_logs

# ----------------------------------------------------------------------------
# Git repositories
# ----------------------------------------------------------------------------

# NUL-delimited read: repository paths may contain spaces, which the original
# `for repo in $(...)` loop would have split apart.
update_git_repos() {
	local base_dir=$1 repo
	[ -d "$base_dir" ] || {
		warn "git tree not found: $base_dir"
		return
	}

	while IFS= read -r -d '' repo; do
		repo=$(dirname "$repo")
		printf 'Updating repository: %s\n' "$repo"
		git -C "$repo" pull --ff-only
	done < <(find "$base_dir" -type d -name .git -prune -print0)
}

log "updating git repositories in background"
update_git_repos "$GIT_TREE" >"$LOG_DIR/git-pull-$DATE.log" 2>&1 &

# ----------------------------------------------------------------------------
# tmux helpers
# ----------------------------------------------------------------------------

# All targeting goes through tmux pane ids (%N). Name-based targets such as
# "work:plain.example.com_123.0" are ambiguous, because tmux reads the dot as
# the window/pane separator and dotted hostnames then fail to resolve.
new_window() {
	local name=$1 dir=${2:-}
	if [ -n "$dir" ]; then
		tmux new-window -t "$SESSION" -n "$name" -c "$dir" -P -F '#{pane_id}'
	else
		tmux new-window -t "$SESSION" -n "$name" -P -F '#{pane_id}'
	fi
}

split_pane() {
	local target=$1 dir=${2:-}
	if [ -n "$dir" ]; then
		tmux split-window -v -t "$target" -c "$dir" -P -F '#{pane_id}'
	else
		tmux split-window -v -t "$target" -P -F '#{pane_id}'
	fi
}

# Log per pane rather than per session: a session target resolves to whichever
# pane happens to be active and silently mislabels logs.
start_pane_logging() {
	local pane=$1
	tmux pipe-pane -t "$pane" "exec cat >>$LOG_DIR/'#W-#P-tmux.log'"
	tmux display-message -t "$pane" "Started logging to $LOG_DIR/#W-#P-tmux.log"
}

run_in_pane() {
	local pane=$1 cmd=$2
	tmux send-keys -t "$pane" "$cmd"
	# AUTORUN_SSH=false leaves the ssh line typed but unexecuted, for hosts that
	# need a touch/2FA confirmation first.
	[ "$AUTORUN_SSH" = "true" ] && tmux send-keys -t "$pane" C-m
	return 0
}

# tmux treats '.' and ':' as target separators, so they cannot appear in a name.
sanitize_name() {
	printf '%s' "${1//[.:]/-}"
}

# tmux fails outright when given a start directory that does not exist, which
# would abort the whole session over a repo that is not cloned yet.
first_existing_dir() {
	local dir
	for dir in "$@"; do
		[ -d "$dir" ] && {
			printf '%s' "$dir"
			return
		}
	done
	printf '%s' "$HOME"
}

# ----------------------------------------------------------------------------
# Session
# ----------------------------------------------------------------------------

if tmux has-session -t "$SESSION" 2>/dev/null; then
	log "killing existing '$SESSION' session"
	tmux kill-session -t "$SESSION"
fi

dev_dir=$(first_existing_dir "$DEV_DIR" "$GIT_TREE")
[ "$dev_dir" = "$DEV_DIR" ] || warn "$DEV_DIR not found; dev window starts in $dev_dir"

log "creating tmux session '$SESSION'"
dev_pane=$(tmux new-session -s "$SESSION" -d -n dev -c "$dev_dir" -P -F '#{pane_id}')

# A tmux server that outlived the old agent still hands the dead SSH_AUTH_SOCK
# to new panes, so every ssh would prompt despite the fresh certificates. Push
# the current agent into the server environment before opening any windows.
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
	tmux setenv -g SSH_AUTH_SOCK "$SSH_AUTH_SOCK"
	tmux setenv -t "$SESSION" SSH_AUTH_SOCK "$SSH_AUTH_SOCK"
fi
if [ -n "${SSH_AGENT_PID:-}" ]; then
	tmux setenv -g SSH_AGENT_PID "$SSH_AGENT_PID"
	tmux setenv -t "$SESSION" SSH_AGENT_PID "$SSH_AGENT_PID"
fi

start_pane_logging "$dev_pane"

tree_dir=$(first_existing_dir "$GIT_TREE")
pane=$(new_window "localhost_$DATE" "$tree_dir")
start_pane_logging "$pane"
for ((i = 1; i < PANES_PER_HOST; i++)); do
	extra=$(split_pane "$pane" "$tree_dir")
	start_pane_logging "$extra"
done
tmux select-layout -t "$pane" even-vertical

if [ -z "$VMS" ]; then
	warn "VMS is empty; no host windows created"
else
	while IFS= read -r vm; do
		[ -n "$vm" ] || continue
		case $vm in \#*) continue ;; esac

		host="${vm%%_*}"
		label="${vm#*_}"
		[ "$label" = "$vm" ] && label=$host

		log "opening window for $host"
		first=$(new_window "$(sanitize_name "$label")_$DATE")
		start_pane_logging "$first"
		run_in_pane "$first" "ssh ${SSH_USERNAME}@${host}"

		for ((i = 1; i < PANES_PER_HOST; i++)); do
			extra=$(split_pane "$first")
			start_pane_logging "$extra"
			run_in_pane "$extra" "ssh ${SSH_USERNAME}@${host}"
		done

		tmux select-layout -t "$first" even-vertical
	done <<<"$VMS"
fi

tmux select-window -t "$dev_pane"
log "attaching to '$SESSION'"
tmux attach -t "$SESSION"
