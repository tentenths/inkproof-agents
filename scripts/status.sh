#!/usr/bin/env bash
# Summarise open request issues and pull requests across this project's
# repositories (names starting with REPO_PREFIX), using your own gh login,
# then each agent's state and recent automatic runs: when, why, how it ended.
#   usage: scripts/status.sh [number of runs per agent, default 5]
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

echo "== Open requests =="
gh search issues --owner "$GH_OWNER" --label request --state open --limit 100 \
  --json repository,number,title,labels \
  | jq -r --arg p "$REPO_PREFIX" '.[] | select(.repository.name | startswith($p))
      | "\(.repository.name)#\(.number)  [\([.labels[].name] | map(select(. != "request")) | join(", "))]  \(.title)"'

echo
echo "== Open pull requests =="
gh search prs --owner "$GH_OWNER" --state open --limit 100 \
  --json repository,number,title,author \
  | jq -r --arg p "$REPO_PREFIX" '.[] | select(.repository.name | startswith($p))
      | "\(.repository.name)#\(.number)  \(.author.login)  \(.title)"'

echo
echo "== Agents =="
[ -e control/paused ] && echo "Paused: scripts/resume.sh resumes them."
for agent in $(docker compose config --services | grep -vx proxy); do
  echo "$agent"
  docker compose exec -T "$agent" run-status "${1:-5}" 2>/dev/null || echo "  container not running"
done
