#!/usr/bin/env bash
# Create a release tag on main, as you (agents cannot create v* tags).
#   usage: scripts/release.sh <repo> <tag>    e.g. scripts/release.sh inkproof-core v0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
repo="${GH_OWNER}/${1:?usage: scripts/release.sh <repo> <tag>}"
tag="${2:?usage: scripts/release.sh <repo> <tag>}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Tag must look like v1.2.3" >&2; exit 1; }
gh release create "$tag" -R "$repo" --target main --generate-notes
