#!/usr/bin/env bash
# Prepare one repository for agents, using your own (admin) gh login:
# request labels, auto-merge, and rulesets for main and release tags.
#   usage: scripts/setup-repo.sh <repo> [autonomy-level]   e.g. inkproof-core 1
#     level 1 (default): agents open pull requests, you approve and merge
#     level 2:           auto-merge is on, so agents' pull requests merge once
#                        checks pass; changes to CODEOWNERS paths (API.lock)
#                        still need you
#     level 3:           as level 2, but API.lock needs the coordinator's
#                        api-lock verdict instead of you, and the coordinator
#                        releases through the gatekeeper (needs APP_ID in .env)
# Re-running replaces this kit's rulesets on the repository; running it with a
# lower level falls back.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
repo="${GH_OWNER}/${1:?usage: scripts/setup-repo.sh <repo> [1|2|3]}"
level="${2:-1}"
case "$level" in
  1) approvals=1 auto_merge=false ;;
  2|3) approvals=0 auto_merge=true ;;
  *) echo "level must be 1, 2 or 3" >&2; exit 1 ;;
esac
if [ "$level" = 3 ] && [ -z "${APP_ID:-}" ]; then
  echo "Level 3 needs the GitHub App: set APP_ID in .env (see README)." >&2
  exit 1
fi

# needs-human replaced needs-approval; rename it so labelled issues keep it.
if gh label list -R "$repo" --json name --jq '.[].name' | grep -qx needs-approval \
   && ! gh label list -R "$repo" --json name --jq '.[].name' | grep -qx needs-human; then
  gh label edit needs-approval -R "$repo" --name needs-human >/dev/null
fi

while IFS='|' read -r name color description; do
  gh label create "$name" -R "$repo" --color "$color" --description "$description" --force >/dev/null
done <<'LABELS'
request|1d76db|Request from another agent
new|fbca04|Not yet triaged by the owner
accepted|0e8a16|Owner will implement it
counter-proposal|c5def5|Owner proposes a different solution
needs-human|d93f0b|Needs the human's decision
ready-for-release|5319e7|Merged; waiting for a release
verified|0e8a16|Requester confirmed the release meets the request
blocked|b60205|Waiting on the issue named in a Blocked-by line
needs-verdict|e99695|Changes API.lock; waiting for the coordinator's api-lock verdict
LABELS

gh api -X PATCH "repos/${repo}" -F allow_auto_merge="$auto_merge" >/dev/null

for name in main release-tags; do
  id="$(gh api "repos/${repo}/rulesets" --jq ".[] | select(.name == \"${name}\") | .id")"
  if [ -n "$id" ]; then
    gh api -X DELETE "repos/${repo}/rulesets/${id}" >/dev/null
  fi
done

# At level 3, main also requires the api-lock check, accepted only from the
# GitHub App, and the App may create release tags.
jq --argjson n "$approvals" --arg level "$level" --arg app "${APP_ID:-0}" '
  (.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = $n
  | if $level == "3" then
      (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
        += [{context: "api-lock", integration_id: ($app | tonumber)}]
    else . end' \
  templates/rulesets/main.json | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null
jq --arg level "$level" --arg app "${APP_ID:-0}" '
  if $level == "3" then
    .bypass_actors += [{actor_id: ($app | tonumber), actor_type: "Integration", bypass_mode: "always"}]
  else . end' \
  templates/rulesets/release-tags.json | gh api -X POST "repos/${repo}/rulesets" --input - >/dev/null

echo "Configured ${repo}: labels, rulesets (autonomy level ${level})."

# Code-owner review of API.lock is the human's gate below level 3; at level 3
# the api-lock check replaces it. CODEOWNERS lives in the repository, so this
# script only checks it.
owners="$(gh api "repos/${repo}/contents/.github/CODEOWNERS" -H 'Accept: application/vnd.github.raw+json' 2>/dev/null || true)"
if [ -z "$owners" ]; then
  echo "Copy templates/repo/ into the repository and set your username in CODEOWNERS."
elif [ "$level" = 3 ] && grep -q '^/API.lock' <<<"$owners"; then
  echo "To finish level 3, remove the /API.lock line from .github/CODEOWNERS, or API.lock still needs your review."
elif [ "$level" != 3 ] && ! grep -q '^/API.lock' <<<"$owners"; then
  echo "Below level 3, put the /API.lock line back in .github/CODEOWNERS, or nothing gates API.lock."
fi
