#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
    # Read the .env file and export variables
    set -o allexport
    source .env
    set +o allexport
else
	echo ".env file not found!"
	exit 1
fi

# Kill any running tmux sessions
pkill -9 tmux

# Current timestamp
date=$(date +%s)

# Move old logs to the archived directory
mv ~/Documents/logs/* ~/Documents/logs/archived/ >/dev/null 2>&1 &

# Function to update all git repositories in a directory
update_git_repos() {
	local base_dir=$1
	repos=$(find "$base_dir" -type d -name ".git" -prune -print0 | xargs -0 -n1 dirname)
	for repo in $repos; do
		echo "Updating repository: ${repo}"
		git -C "${repo}" pull
	done
}

# Update all git repositories in ~/Documents/work/git_tree/
update_git_repos ~/Documents/work/git_tree >/dev/null 2>&1 &

# Start a new tmux session
tmux new -s work -d
tmux rename-window -t work "localhost_${date}"
tmux send-keys -t work "cd ~/Documents/work/git_tree" C-m
tmux send-keys -t work C-m

# Loop through each VM and create a new tmux window for each
IFS=$'\n' # Set Internal Field Separator to newline
for vm in $VMS; do
	ip=$(echo "${vm}" | cut -d'_' -f1)
	host=$(echo "${vm}" | cut -d'_' -f2)
	window_name="${host}_${date}"

	tmux new-window -t work -n "$window_name"
	tmux select-window -t "${window_name}"
	tmux pipe-pane -t work "exec cat >>${HOME}/Documents/logs/'#W-tmux.log'" \; display-message "Started logging to ${HOME}/Documents/logs/#W-tmux.log"
	tmux send-keys -t work "ssh ${SSH_USERNAME}@${ip}" C-m
	tmux send-keys -t work C-m
done

# Select the localhost window and attach to the tmux session
tmux select-window -t "localhost_${date}"
tmux attach -t work
