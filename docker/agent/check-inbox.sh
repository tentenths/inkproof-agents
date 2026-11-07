#!/usr/bin/env bash
# Claude Code Stop hook.
# If the agent's own repository has untriaged request issues (labels
# "request" and "new") opened by a trusted author, block the stop (exit 2)
# and tell Claude why. The owner triages by removing the "new" label (see
# PROTOCOL.md), so the hook stops firing once everything is triaged.
# Issues from anyone not in TRUSTED_AUTHORS are ignored.
# Whenever it lets Claude stop, it records the session as idle for watch-work.
set -uo pipefail

input="$(cat)"
state=/workspace/.inkproof

allow_stop() {
  mkdir -p "$state"
  printf 'idle %s\n' "$(date +%s)" > "$state/activity"
  printf '%s' "$input" | jq -r '.transcript_path // empty' > "$state/transcript"
  exit 0
}

# Avoid loops: if Claude is already continuing because of this hook, let it stop.
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" = "true" ]; then
  allow_stop
fi

# While the human has paused the agents, let every session stop.
[ -e /etc/inkproof/control/paused ] && allow_stop

# The coordinator has no inbox of its own; it sweeps all repositories by role.
[ "${AGENT_NAME:-}" = "coordinator" ] && allow_stop

repo="${GH_OWNER}/${AGENT_REPO}"
trusted_json="$(printf '%s\n' ${TRUSTED_AUTHORS:-} | jq -R . | jq -s .)"

if ! issues="$(gh issue list -R "$repo" --state open --label request --label new \
                 --json number,title,author --limit 50 2>/dev/null)"; then
  # Never trap the agent because GitHub is unreachable.
  allow_stop
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

allow_stop
