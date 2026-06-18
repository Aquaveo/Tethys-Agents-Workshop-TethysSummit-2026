#!/usr/bin/env bash
# tethys-agents-workshop - one-shot setup for fresh hosts.
#
#   1. Clone (or fast-forward) the three source repos at the configured refs.
#   2. docker compose pull || docker compose build.
#   3. docker compose up -d.
#   4. Wait for ollama to be healthy, then pull the default model.
#
# Re-runnable. Branch refs ff-pull cleanly; SHA refs detach (per pattern
# in workshops/devcon).

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
else
  echo "[setup] .env not found - copying from .env.example"
  cp .env.example .env
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

# ---------------------------------------------------------------------------
# 1. Clone or fast-forward each repo at its configured ref.
# ---------------------------------------------------------------------------
clone_or_pull() {
  # NOTE: separate `local` statements, not `local a=.. b=.. c="..${a}.."`.
  # Bash's multi-name `local` evaluates ALL right-hand sides before binding
  # names, so a cross-reference like `dest="repos/${name}"` resolves against
  # the OUTER scope - which under `set -u` aborts with "name: unbound
  # variable". Splitting the declarations makes each binding visible to the
  # next assignment's RHS.
  local name="$1"
  local url="$2"
  local ref="$3"
  local dest="repos/${name}"
  if [[ -d "${dest}/.git" ]]; then
    echo "[setup] ${name}: fetching + checkout ${ref}"
    git -C "${dest}" fetch --quiet --tags origin
    git -C "${dest}" checkout --quiet "${ref}" || {
      echo "[setup] ${name}: ref ${ref} not found locally; trying origin/${ref}"
      git -C "${dest}" checkout --quiet "origin/${ref}"
    }
    git -C "${dest}" pull --ff-only --quiet origin "${ref}" 2>/dev/null || true
  else
    echo "[setup] ${name}: cloning at ${ref}"
    git clone --quiet "${url}" "${dest}"
    git -C "${dest}" checkout --quiet "${ref}"
  fi
}

clone_or_pull tethysapp-tethys_dash \
  https://github.com/tethysplatform/tethysapp-tethys_dash.git \
  "${TETHYSDASH_REF:-feat/agent-tool-packages}"

clone_or_pull tethys-agents \
  https://github.com/Aquaveo/tethys-agents.git \
  "${TETHYS_AGENTS_REF:-main}"

clone_or_pull geoglows-summit-plugin-example \
  https://github.com/Aquaveo/geoglows-summit-plugin-example.git \
  "${GEOGLOWS_REF:-main}"

# ---------------------------------------------------------------------------
# 2. Pull or build the workshop image.
# ---------------------------------------------------------------------------
echo "[setup] docker compose pull || build"
docker compose pull --ignore-pull-failures 2>/dev/null || true
docker compose build

# ---------------------------------------------------------------------------
# 3. Start everything.
# ---------------------------------------------------------------------------
echo "[setup] docker compose up -d"
docker compose up -d

# ---------------------------------------------------------------------------
# 4. Pull the default LLM model into ollama (once ollama is healthy).
# ---------------------------------------------------------------------------
echo "[setup] waiting for ollama to be healthy..."
for _ in $(seq 1 30); do
  if docker compose ps ollama --format '{{.Health}}' 2>/dev/null | grep -q healthy; then
    break
  fi
  sleep 2
done

MODEL="${AGENT_MODEL:-qwen3:8b}"
echo "[setup] pulling ollama model: ${MODEL} (skipped if already present)"
docker compose exec -T ollama ollama list | grep -q "^${MODEL%:*}\b" || \
  docker compose exec -T ollama ollama pull "${MODEL}"

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
cat <<EOF

[setup] complete.

  Browser:    http://localhost:8000/apps/tethysdash/
  CLI:        docker compose exec tethysdash tethysdash chat --user admin
  Logs:       docker compose logs -f tethysdash
  Plugin:     edit files under ./repos/geoglows-summit-plugin-example/
              (Django auto-reloads on .py change)
  Stop:       docker compose down
  Reset all:  scripts/reset.sh

EOF
