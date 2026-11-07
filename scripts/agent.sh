#!/usr/bin/env bash
# Attach to an agent's Claude Code session, starting it if needed.
# The session runs inside tmux in the container, so it survives detaching
# (Ctrl-b d) and closing your terminal. If Claude exits, the window stays
# open so you can read any error; press Enter to restart Claude, or Ctrl-b d
# to detach.
#   usage: scripts/agent.sh <agent> [extra claude args...]
set -euo pipefail
cd "$(dirname "$0")/.."
agent="${1:?usage: scripts/agent.sh <agent> [claude args...]}"; shift || true

args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done

loop="cd \"/workspace/\$AGENT_REPO\" || exit 1; while true; do claude --remote-control \"\$AGENT_NAME\"${args}; status=\$?; echo; echo \"Claude exited (status \$status). Press Enter to restart it, or Ctrl-b d to detach.\"; read -r _; done"

docker compose exec -it "$agent" tmux new-session -A -s claude bash -c "$loop"
