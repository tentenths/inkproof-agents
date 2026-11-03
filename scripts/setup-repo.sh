#!/usr/bin/env bash
# Prepare one repository for agents, using your own (admin) gh login:
# request labels, and rulesets for main and release tags.
#   usage: scripts/setup-repo.sh <repo> [autonomy-level]   e.g. inkproof-core 1
#     level 1 (default): agents open pull requests, you approve and merge
#     level 2:           agents merge their own pull requests once checks pass;
#                        changes to CODEOWNERS paths (API.lock) still need you
# Re-running replaces this kit's rulesets on the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
repo="${GH_OWNER}/${1:?usage: scripts/setup-repo.sh <repo> [1|2]}"
level="${2:-1}"
case "$level" in 1) approvals=1 ;; 2) approvals=0 ;; *) echo "level must be 1 or 2" >&2; exit 1 ;; esac

while IFS='|' read -r name color description; do
  gh label create "$name" -R "$repo" --color "$color" --description "$description" --force >/dev/null
done <<'LABELS'
request|1d76db|Request from another agent
new|fbca04|Not yet triaged by the owner
accepted|0e8a16|Owner will implement it
counter-proposal|c5def5|Owner proposes a different solution
needs-approval|d93f0b|Would change API.lock; the human decides
ready-for-release|5319e7|Merged; waiting for a release
verified|0e8a16|Requester confirmed the release meets the request
LABELS

for name in main release-tags; do
  id="$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\") | .id")"
  if [ -n "$id" ]; then
    gh api -X DELETE "repos/${repo}/rulesets/${id}" >/dev/null
  fi
done

jq --argjson n "$approvals" \
  '(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = $n' \
  templates/rulesets/main.json | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null
gh api -X POST "repos/${repo}/rulesets" --input templates/rulesets/release-tags.json >/dev/null

echo "Configured ${repo}: labels, rulesets (autonomy level ${level})."
echo "Copy templates/repo/ into the repository and set your username in CODEOWNERS."
