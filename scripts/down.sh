#!/usr/bin/env bash
# Stop and remove every container this kit runs, the gatekeeper included, and
# their networks. Volumes are kept: each agent's workspace and run log, the
# shared Claude login, and the gatekeeper's state. scripts/up.sh starts them
# again.
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose --profile gatekeeper down
