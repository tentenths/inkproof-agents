#!/usr/bin/env bash
# Build and start the proxy and every agent container. Each agent clones its
# repository on first start, then idles until you attach.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Create .env from .env.example first." >&2; exit 1; }

missing=0
for f in $(docker compose config --format json | jq -r '.secrets[].file'); do
  if [ ! -s "$f" ]; then echo "Missing token file: $f" >&2; missing=1; fi
done
[ "$missing" = 0 ] || { echo "Create the tokens listed above (see README)." >&2; exit 1; }

# Shared with other projects on this machine, so compose.yaml declares it
# external rather than creating it. Does nothing if it already exists.
docker volume create elan-shared >/dev/null

docker compose up -d --build
docker compose ps
