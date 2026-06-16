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
