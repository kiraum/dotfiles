#!/usr/bin/env bash
#
# Start a tmux work session: a localhost window plus one logged SSH window per VM.
#
# VMs and the SSH user come from an env file (default: ~/.env), one "ip_hostname" per line:
#   VMS="192.0.2.10_host-a
#   192.0.2.11_host-b"
#   SSH_USERNAME=user

set -euo pipefail

git_root="$HOME/Documents/work/git_tree"
logs_dir="$HOME/Documents/logs"
env_file="$HOME/.env"
session=""
work_dir=""
update_repos=true

usage() {
	cat <<EOF
Usage: $(basename "$0") [options] [profile]

Profiles:
  work   (default) session "work", starts in $git_root
  ixp    session "work_ixbr", starts in $git_root/ixbr

Options:
  -s NAME   tmux session name (overrides the profile)
  -d DIR    starting directory of the localhost window (overrides the profile)
  -e FILE   env file to load (default: $env_file)
  -n        don't update git repositories
  -h        show this help
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

while getopts ":s:d:e:nh" opt; do
	case $opt in
		s) session=$OPTARG ;;
		d) work_dir=$OPTARG ;;
		e) env_file=$OPTARG ;;
		n) update_repos=false ;;
		h) usage; exit 0 ;;
		:) usage >&2; die "Option -$OPTARG requires an argument" ;;
		*) usage >&2; die "Unknown option: -$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))

case ${1:-work} in
	work)
		session=${session:-work}
		work_dir=${work_dir:-$git_root}
		;;
	ixp)
		session=${session:-work_ixbr}
		work_dir=${work_dir:-$git_root/ixbr}
		;;
	*) usage >&2; die "Unknown profile: $1" ;;
esac

command -v tmux >/dev/null || die "tmux is not installed"
[[ -f $env_file ]] || die "Env file not found: $env_file"
[[ -d $work_dir ]] || die "Directory not found: $work_dir"

set -o allexport
# shellcheck source=/dev/null
source "$env_file"
set +o allexport

: "${VMS:?VMS is not set in $env_file}"
: "${SSH_USERNAME:?SSH_USERNAME is not set in $env_file}"

date=$(date +%s)

# Ask for the key passphrase once, so the background git pulls and the VM windows can use the agent.
if [[ -t 0 ]] && ! ssh-add -l >/dev/null 2>&1; then
	ssh-add || echo "Could not add SSH key to the agent; git updates and VM logins may fail" >&2
fi

mkdir -p "$logs_dir/archived"
find "$logs_dir" -maxdepth 1 -type f -exec mv {} "$logs_dir/archived/" \;

update_git_repos() {
	local git_dir repo
	find "$1" -type d -name .git -prune -print0 |
		while IFS= read -r -d '' git_dir; do
			repo=$(dirname "$git_dir")
			echo "==> $repo"
			git -C "$repo" pull --ff-only || echo "!! pull failed: $repo"
		done
}

if $update_repos; then
	GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
		update_git_repos "$git_root" >"$logs_dir/git-update-$date.log" 2>&1 </dev/null &
fi

# Build under a temporary name and swap it in afterwards: killing the old session first can
# leave the server with no sessions, and it exits while we are still talking to it.
tmp_session="${session}_$date"
tmux new-session -d -s "$tmp_session" -n "localhost_$date" -c "$work_dir"

while read -r vm; do
	[[ -z $vm || $vm == \#* ]] && continue
	ip=${vm%%_*}
	host=${vm#*_}
	window="${host}_${date}"

	win_id=$(tmux new-window -d -P -F '#{window_id}' -t "$tmp_session:" -n "$window")
	tmux pipe-pane -t "$win_id" "exec cat >>'$logs_dir/$window-tmux.log'"
	tmux send-keys -t "$win_id" "ssh $SSH_USERNAME@$ip" C-m
done <<<"$VMS"

if [[ -n ${TMUX:-} ]]; then
	tmux switch-client -t "=$tmp_session" 2>/dev/null || true
fi

# One tmux invocation, so the swap completes even when run from inside the session being replaced.
swap=()
tmux has-session -t "=$session" 2>/dev/null && swap+=(kill-session -t "=$session" \;)
swap+=(rename-session -t "=$tmp_session" "$session")
tmux "${swap[@]}"

[[ -n ${TMUX:-} ]] || exec tmux attach -t "=$session"
