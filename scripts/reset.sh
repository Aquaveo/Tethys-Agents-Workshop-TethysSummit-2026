#!/usr/bin/env bash
# Nuke + re-clone. Use when the workshop image / persistent state / cloned
# repos are in a bad state and you want a clean slate.
#
# Spares: the Ollama model cache (named volume `..._ollama-models`) - these
# are multi-GB downloads and almost never the cause of breakage.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

read -r -p "About to docker compose down -v (tethys-persist) AND rm -rf ./repos/. Continue? [y/N] " ans
[[ "${ans,,}" == "y" ]] || { echo "aborted."; exit 1; }

echo "[reset] stopping containers + dropping tethys-persist volume"
docker compose down

# Drop only the tethys-persist volume; keep ollama-models.
docker volume rm -f tethys-agents-workshop_tethys-persist 2>/dev/null || true

echo "[reset] removing ./repos/"
rm -rf ./repos/
mkdir -p ./repos/

echo "[reset] re-running setup.sh..."
exec scripts/setup.sh
