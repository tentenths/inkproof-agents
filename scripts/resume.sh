#!/usr/bin/env bash
# Undo scripts/pause.sh: switch auto-merge back on where pause held it, then
# let agents start sessions again. Work that arrived while paused starts then.
# Auto-merge switched on here merges in your name, not the machine user's.
set -euo pipefail
cd "$(dirname "$0")/.."
held=control/held-auto-merge

if [ -f "$held" ]; then
  while read -r repo n method; do
    [ "$(gh pr view -R "$repo" "$n" --json state --jq .state)" = OPEN ] || continue
    gh pr merge --auto "--$(printf %s "$method" | tr "[:upper:]" "[:lower:]")" -R "$repo" "$n" >/dev/null
    echo "Auto-merge back on for ${repo}#${n}"
  done < "$held"
  rm -f "$held"
fi

rm -f control/paused
echo "Resumed."
