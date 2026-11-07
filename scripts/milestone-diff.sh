#!/usr/bin/env bash
# Every repository's API.lock diff across a milestone, for your review when
# accepting it, using your own gh login. Each diff runs from the last release
# published before the start date (or from nothing) to the last one published
# before the end date (default: now). Releases on the start date count as part
# of the milestone.
#   usage: scripts/milestone-diff.sh <start-date> [end-date]   e.g. 2026-11-01
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
start="${1:?usage: scripts/milestone-diff.sh <start-date> [end-date]}"
end="${2:-9999-12-31}"

lock() {
  [ -n "$2" ] || return 0
  gh api "repos/${GH_OWNER}/$1/contents/API.lock?ref=$2" \
    -H 'Accept: application/vnd.github.raw+json' 2>/dev/null || true
}

for repo in $(gh repo list "$GH_OWNER" --limit 500 --json name --jq '.[].name' | grep "^${REPO_PREFIX}" | sort); do
  releases="$(gh release list -R "${GH_OWNER}/${repo}" --limit 500 --json tagName,publishedAt \
    --jq '.[] | "\(.publishedAt) \(.tagName)"' | sort)"
  from="$(awk -v d="$start" '$1 < d { t = $2 } END { print t }' <<<"$releases")"
  to="$(awk -v d="$end" '$1 < d { t = $2 } END { print t }' <<<"$releases")"
  if [ -z "$to" ] || [ "$to" = "$from" ]; then
    echo "== ${repo}: no release in the milestone"
    continue
  fi
  echo "== ${repo}: ${from:-nothing} to ${to}"
  diff -u <(lock "$repo" "$from") <(lock "$repo" "$to") | tail -n +3 || true
done
