#!/usr/bin/env bash
# Pause every agent, using your own gh login: no new sessions start, running
# ones stop at their next stop, and auto-merge is switched off on open pull
# requests until scripts/resume.sh switches it back on.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
mkdir -p control
touch control/paused
held=control/held-auto-merge

for repo in $(gh repo list "$GH_OWNER" --limit 500 --json name --jq '.[].name' | grep "^${REPO_PREFIX}"); do
  gh pr list -R "$GH_OWNER/$repo" --state open --json number,autoMergeRequest \
    --jq '.[] | select(.autoMergeRequest != null) | "\(.number) \(.autoMergeRequest.mergeMethod)"' \
  | while read -r n method; do
      gh pr merge --disable-auto -R "$GH_OWNER/$repo" "$n" >/dev/null
      echo "$GH_OWNER/$repo $n $method" >> "$held"
      echo "Held auto-merge on $repo#$n"
    done
done

echo "Paused."
running=""
for a in $(docker compose config --services | grep -vx proxy); do
  docker compose exec -T "$a" test -e /workspace/.inkproof/current 2>/dev/null && running+=" $a"
done
if [ -n "$running" ]; then
  echo "Still running:${running}. They stop at their next stop; run scripts/pause.sh"
  echo "again then, to hold any auto-merge they switched on meanwhile."
fi
