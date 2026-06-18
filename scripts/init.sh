#!/usr/bin/env bash
# Container-side init for the tethysdash service.
#
# Runs once per container start. Idempotent: existing DB / persistent store
# / superuser are detected and skipped. Then exec's `tethys manage start`
# which serves the Django dev server (auto-reload on .py change).
#
# Marker file lives under TETHYS_PERSIST so it survives container restarts
# but is wiped by `scripts/reset.sh` (which deletes the named volume).

set -euo pipefail

MARKER="${TETHYS_PERSIST}/.workshop-init-complete"

# Re-install the three editable workshop repos on every container start.
# This handles the case where the bind-mount shadowed the image's pre-baked
# install with a host directory that lacks the .egg-info / .pth records.
# Cheap when nothing changed; necessary the first time the bind-mount lands.
echo "[init] ensuring editable installs are healthy..."
for repo in tethys-agents tethysapp-tethys_dash geoglows-summit-plugin-example; do
  if [[ -f "${TETHYS_APPS_ROOT}/${repo}/pyproject.toml" ]]; then
    pip install --quiet --no-deps -e "${TETHYS_APPS_ROOT}/${repo}" 2>/dev/null \
      || echo "[init] warn: pip install -e ${repo} returned non-zero (continuing)"
  fi
done

# Symlink frontend/main.js -> main.<contenthash>.js. tethysdash's controllers.py
# resolves the bundle to UNHASHED "frontend/main.js" under DEBUG=True (assumes
# webpack-dev-server), but the cloned feat/agent-tool-packages branch ships only
# the production webpack output: hashed chunk files + a manifest.json. Without
# this symlink the browser GETs /static/tethysdash/frontend/main.js and 404s,
# rendering the dashboard blank. Runs every container start so it survives a
# bundle rebuild (the hashed filename changes per build).
FRONTEND_DIR="${TETHYS_APPS_ROOT}/tethysapp-tethys_dash/tethysapp/tethysdash/public/frontend"
if [[ -d "${FRONTEND_DIR}" && -f "${FRONTEND_DIR}/manifest.json" ]]; then
  HASHED=$(python -c "import json,sys; print(json.load(open('${FRONTEND_DIR}/manifest.json')).get('main.js',''))" 2>/dev/null || true)
  if [[ -n "${HASHED}" && -f "${FRONTEND_DIR}/${HASHED}" ]]; then
    ln -sf "${HASHED}" "${FRONTEND_DIR}/main.js"
    echo "[init] symlinked frontend/main.js -> ${HASHED}"
  else
    echo "[init] warn: could not resolve main.js from manifest.json (UI will 404)"
  fi
fi

if [[ ! -f "${MARKER}" ]]; then
  echo "[init] first-run setup..."

  # Tethys platform DB (the meta DB, not the app's persistent store).
  echo "[init] tethys db init / migrate"
  tethys db init 2>/dev/null || true
  tethys db migrate

  # Superuser - non-interactive create with the workshop's defaults.
  echo "[init] creating superuser 'admin' / 'admin' (workshop default - change before prod)"
  PORTAL_SUPERUSER_NAME=admin \
  PORTAL_SUPERUSER_PASSWORD=admin \
  PORTAL_SUPERUSER_EMAIL=admin@workshop.local \
    tethys db createsuperuser 2>/dev/null || true

  # Wire tethysdash's PersistentStoreDatabaseSetting "primary_db" to a
  # SQLitePersistentStoreService. The portal_config.yml shape
  # (apps.tethysdash.PERSISTENT_STORES.primary_db: {URL, SPATIAL}) is NOT
  # honored by Tethys's loader - it expects a separately-created
  # PersistentStoreService row + an explicit `tethys link`. Without both,
  # syncstores raises TethysAppSettingNotAssigned and the chat agent's DB
  # writes have nowhere to go. Both commands are idempotent:
  #   - `services create` prints "already exists" (exit 0) on re-run
  #   - `link` re-applies cleanly when the link already exists
  echo "[init] creating + linking tethysdash_primary SQLite service"
  tethys services create persistent \
    -n tethysdash_primary -t sqlite -d "${TETHYS_PERSIST}" 2>&1 | tail -2
  tethys link \
    persistent:tethysdash_primary tethysdash:ps_database:primary_db 2>&1 | tail -2

  # App persistent store (the SQLite file the AGENT chain writes to).
  echo "[init] tethysdash syncstores"
  tethys syncstores tethysdash --firsttime || true

  # Static / media collected once.
  echo "[init] tethys manage collectstatic"
  tethys manage collectstatic --noinput >/dev/null

  touch "${MARKER}"
  echo "[init] first-run complete."
else
  echo "[init] reusing existing persistent store (marker: ${MARKER})"
fi

echo "[init] starting tethys manage start (Django dev server, auto-reload)"
exec tethys manage start --port 0.0.0.0:8000
