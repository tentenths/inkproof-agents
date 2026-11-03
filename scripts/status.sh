#!/usr/bin/env bash
# Summarise open request issues and pull requests across this project's
# repositories (names starting with REPO_PREFIX), using your own gh login.
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
