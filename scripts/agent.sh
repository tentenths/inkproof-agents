#!/usr/bin/env bash
# Attach to an agent's Claude Code session, starting it if needed.
# The session runs inside tmux in the container, so it survives detaching
# (Ctrl-b d) and closing your terminal.
#   usage: scripts/agent.sh <agent> [extra claude args...]
set -euo pipefail
cd "$(dirname "$0")/.."
agent="${1:?usage: scripts/agent.sh <agent> [claude args...]}"; shift || true
docker compose exec -it "$agent" tmux new-session -A -s claude claude "$@"
