# syntax=docker/dockerfile:1
#
# tethysdash + tethys-agents + geoglows-summit-plugin-example workshop image.
#
# Multi-stage uv build modeled on tethys-architecture/Dockerfile:
#   base    — shared ENV
#   builder — uv installs Python + venv + tethys-platform + the three editable repos
#   runtime — slim image: just the venv + runtime libs
#
# The three workshop repos (tethysdash, tethys-agents, geoglows-summit-plugin-example)
# are installed `-e` (editable) at exactly the same paths the docker-compose.yml
# bind-mounts on top of. This is load-bearing: the editable install records
# absolute paths, and the bind-mount preserves those paths, so participant edits
# to ./repos/<name>/ on the host are visible to Python inside the container with
# no rebuild. Django's dev server auto-reloads on .py change.

###############################################################################
# base — shared environment
###############################################################################
FROM debian:trixie-slim AS base

ENV HOME="/home/tethys" \
    TETHYS_HOME="/home/tethys/portal" \
    TETHYS_LOG="/home/tethys/log" \
    TETHYS_PERSIST="/home/tethys/persist" \
    TETHYS_APPS_ROOT="/workspaces" \
    VIRTUAL_ENV="/opt/venv" \
    PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1

###############################################################################
# builder — heavy toolchain; nothing here lands in the final image
###############################################################################
FROM base AS builder

# uv binary (build-time only)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Build deps: git for cloning, gcc/libpq-dev for any wheel-less Python pkg.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates git gcc libpq-dev \
  && rm -rf /var/lib/apt/lists/*

ENV UV_PYTHON_PREFERENCE=only-managed \
    UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_COMPILE_BYTECODE=1

WORKDIR ${TETHYS_HOME}

# Workshop-side pyproject (just declares the Python version + base deps).
COPY pyproject.toml .

# Python interpreter + venv + tethys-platform.
RUN uv python install 3.12 \
  && uv venv "${VIRTUAL_ENV}" --python 3.12 \
  && uv pip install --no-cache \
       "tethys-platform @ git+https://github.com/tethysplatform/tethys.git" \
  && uv pip install --no-cache -r pyproject.toml \
  && tethys gen portal_config

# --------------------------------------------------------------------------
# Workshop repos — clone at the configured refs, install -e under /workspaces.
# Build args let .env / docker-compose override the branch refs at build time.
# --------------------------------------------------------------------------
ARG TETHYSDASH_REPO=https://github.com/tethysplatform/tethysapp-tethys_dash.git
ARG TETHYSDASH_REF=feat/agent-tool-packages
ARG TETHYS_AGENTS_REPO=https://github.com/Aquaveo/tethys-agents.git
ARG TETHYS_AGENTS_REF=main
ARG GEOGLOWS_REPO=https://github.com/Aquaveo/geoglows-summit-plugin-example.git
ARG GEOGLOWS_REF=main

# tethys-agents first (tethysdash imports from it).
RUN git clone --depth 1 --branch "${TETHYS_AGENTS_REF}" \
       "${TETHYS_AGENTS_REPO}" "${TETHYS_APPS_ROOT}/tethys-agents" \
  && uv pip install --no-cache -e "${TETHYS_APPS_ROOT}/tethys-agents"

# tethysdash — the host app.
RUN git clone --depth 1 --branch "${TETHYSDASH_REF}" \
       "${TETHYSDASH_REPO}" "${TETHYS_APPS_ROOT}/tethysapp-tethys_dash" \
  && uv pip install --no-cache -e "${TETHYS_APPS_ROOT}/tethysapp-tethys_dash"

# geoglows-summit-plugin-example — the editable plugin participants modify.
RUN git clone --depth 1 --branch "${GEOGLOWS_REF}" \
       "${GEOGLOWS_REPO}" "${TETHYS_APPS_ROOT}/geoglows-summit-plugin-example" \
  && uv pip install --no-cache -e "${TETHYS_APPS_ROOT}/geoglows-summit-plugin-example"

# Bake the workshop portal_config (AGENT_PLUGIN_PACKAGES, AGENT_MODEL, ollama URL).
COPY portal_config.yml ${TETHYS_HOME}/portal_config.yml

# World-readable so the non-root runtime user can execute.
RUN chmod -R a+rX /opt/python /opt/venv

###############################################################################
# runtime — slim image
###############################################################################
FROM base AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl postgresql-client \
  && rm -rf /var/lib/apt/lists/*

# Non-root service user.
RUN useradd --uid 1000 --create-home --home-dir /home/tethys --shell /bin/bash tethys

# Interpreter + venv from builder.
COPY --from=builder /opt/python /opt/python
COPY --from=builder /opt/venv   /opt/venv

# The three editable installs from /workspaces — copied so they exist if the
# bind-mount is missing (smoke tests, CI). At runtime the docker-compose
# bind-mount overlays these with the host source.
COPY --from=builder ${TETHYS_APPS_ROOT} ${TETHYS_APPS_ROOT}

# Portal config + entry-point shim.
COPY --from=builder ${TETHYS_HOME}/portal_config.yml ${TETHYS_HOME}/portal_config.yml
COPY --chmod=0755 scripts/init.sh /usr/local/bin/init.sh

# Make the home tree owned by uid 1000.
RUN chown -R 1000:1000 /home/tethys "${TETHYS_APPS_ROOT}"

USER 1000:1000

RUN mkdir -p "${TETHYS_HOME}/keys" "${TETHYS_PERSIST}" "${TETHYS_LOG}"

VOLUME ["${TETHYS_PERSIST}"]
WORKDIR ${TETHYS_HOME}
EXPOSE 8000

# init.sh syncs the persistent store on first run (idempotent), then execs
# `tethys manage start` which auto-reloads on .py change.
CMD ["/usr/local/bin/init.sh"]
