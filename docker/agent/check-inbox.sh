#!/usr/bin/env bash
# Claude Code Stop hook.
# If the agent's own repository has untriaged request issues (labels
# "request" and "new") opened by a trusted author, block the stop (exit 2)
# and tell Claude why. The owner triages by removing the "new" label (see
# PROTOCOL.md), so the hook stops firing once everything is triaged.
# Issues from anyone not in TRUSTED_AUTHORS are ignored.
set -uo pipefail

input="$(cat)"

# Avoid loops: if Claude is already continuing because of this hook, let it stop.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
  exit 0
fi

# The coordinator has no inbox of its own; it sweeps all repositories by role.
[ "${AGENT_NAME:-}" = "coordinator" ] && exit 0

repo="${GH_OWNER}/${AGENT_REPO}"
trusted_json="$(printf '%s\n' ${TRUSTED_AUTHORS:-} | jq -R . | jq -s .)"

if ! issues="$(gh issue list -R "$repo" --state open --label request --label new \
                 --json number,title,author --limit 50 2>/dev/null)"; then
  # Never trap the agent because GitHub is unreachable.
  exit 0
fi

pending="$(printf '%s' "$issues" | jq -r --argjson trusted "$trusted_json" '
  [.[] | select(.author.login as $a | $trusted | index($a))]
  | .[] | "  - #\(.number) \(.title)"')"

if [ -n "$pending" ]; then
  {
    echo "Untriaged requests are waiting on ${repo}:"
    echo "$pending"
    echo "Triage each one as described in /etc/claude-code/PROTOCOL.md before stopping."
  } >&2
  exit 2
fi

exit 0
