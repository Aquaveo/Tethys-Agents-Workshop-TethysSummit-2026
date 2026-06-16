# tethys-agents-workshop

Containerized workshop scaffold for **TethysDash + tethys-agents** with the
**geoglows-summit-plugin-example** as the editable target. Participants
write Python agents and visualization plugins; tethys-platform serves the
dashboard; Ollama runs the LLM locally.

## What's in the box

| Service | Role | Port |
|---|---|---|
| `tethysdash` | Django + tethys-agents + your editable plugin | `127.0.0.1:8000` |
| `ollama` | Local LLM backend (default model: `qwen3:8b`) | `127.0.0.1:11434` |

Three repos are cloned into `./repos/` by `setup.sh` and bind-mounted into
the tethysdash container:

| Repo | Path | Default ref |
|---|---|---|
| [tethysapp-tethys_dash](https://github.com/tethysplatform/tethysapp-tethys_dash) | `./repos/tethysapp-tethys_dash` | `feat/agent-tool-packages` |
| [tethys-agents](https://github.com/Aquaveo/tethys-agents) | `./repos/tethys-agents` | `main` |
| [geoglows-summit-plugin-example](https://github.com/Aquaveo/geoglows-summit-plugin-example) | `./repos/geoglows-summit-plugin-example` | `main` |

All three are installed `-e` (editable) inside the container at the same
path the bind-mount overlays - your edits hot-reload via Django's dev
server with no rebuild.

## Quickstart

```bash
# Clone the workshop
git clone https://github.com/Aquaveo/tethys-agents-workshop
cd tethys-agents-workshop
cp .env.example .env             # edit refs / model if needed

# Verify host prerequisites + (best-effort) auto-install Docker / git
# if missing. Safe to re-run; idempotent. Skip if you know Docker +
# docker compose v2 are already installed.
./scripts/pre-setup.sh

# Clone source repos, build image, pull model, start everything
./scripts/setup.sh
```

> **Note:** `pre-setup.sh` will prompt before any sudo install. Pass
> `--yes` / `-y` to skip prompts (useful for CI / classroom imaging).
> On Linux, if it installed Docker for you, you must log out and back
> in (or `newgrp docker`) before `setup.sh` will succeed.

Then open:

* Dashboard: <http://localhost:8000/apps/tethysdash/> (login `admin` / `admin`)
* Chat agent (terminal):
  ```bash
  docker compose exec tethysdash tethysdash chat --user admin --runner multi
  ```

## Editing the plugin

```bash
# Edit anything under here - Django auto-reloads on save:
$EDITOR repos/geoglows-summit-plugin-example/src/geoglows_summit_example/...
```

Plugin layout (after the recent reorganization):

```
src/geoglows_summit_example/
├── cache.py                   # data layer
├── observed.py                # data layer
├── sintetic.py                # data layer
├── tools/                     # LLM-callable tool surface
│   ├── main.py                # 6 public tools
│   └── utils.py               # internal formatting helpers
├── agent/                     # chat-agent runners
│   ├── prompts.py             # backstories + plugin mapping table
│   ├── runners.py             # _SingleRunner, _CrewRunner
│   └── __init__.py            # RUNNERS dict (the harness reads this)
└── viz/                       # Plotly viz plugins (intake DataSources)
    ├── bias_corrected_from_cache.py
    ├── forecast_viewer.py
    ├── observed_from_cache.py
    └── retrospective_from_cache.py
```

The agent's `RUNNERS` dict, the tools' module functions, and the viz
classes are all discovered automatically - no entry-point file to update
when you add a new tool or viz plugin.

## Commands

| Goal | Command |
|---|---|
| Check + install host prerequisites (Docker, git, etc.) | `./scripts/pre-setup.sh` |
| First-time setup | `./scripts/setup.sh` |
| Stop everything | `docker compose down` |
| Logs (live) | `docker compose logs -f tethysdash` |
| Open shell in container | `docker compose exec tethysdash bash` |
| Pull a different LLM model | `docker compose exec ollama ollama pull <model>` |
| Wipe + reclone (keeps Ollama models) | `./scripts/reset.sh` |

## VS Code Dev Containers

The `.devcontainer/devcontainer.json` is wired to the `tethysdash` compose
service. From VS Code, "Reopen in Container" attaches to the running
tethysdash with the venv's interpreter, Pylance pointed at all three
bind-mounted repos.

## Architecture notes

* **Why uv?** Multi-stage build that's ~3× faster than pip on a cold
  cache, mirrors `tethys-architecture/Dockerfile`.
* **Why editable installs?** The bind-mount preserves the `-e` paths
  exactly, so Python imports the host source live. Edits hot-reload via
  Django's `manage start` dev server.
* **Why `127.0.0.1` binds?** Workshop laptops shouldn't expose Tethys or
  Ollama on the LAN. SSH tunnel `-L 8000` if you're remoting in.
* **Why one `AGENTS` block?** A package can contribute `<pkg>.tools`,
  `<pkg>.agent`, or both. Each discovery layer picks the submodule it
  needs and silently skips packages that don't expose it - so a single
  `AGENTS.PACKAGES` list covers tool packages, runner packages, and
  packages that ship both. `MODELS[0]` is the default model (CLI
  `--model` picks any other value); `MODE` is the default runner name
  (CLI `--runner` overrides).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `tethysdash chat` says "AGENTS.PACKAGES is empty" | `portal_config.yml` wasn't picked up | `docker compose down && docker compose up -d` |
| `ModuleNotFoundError: geoglows_summit_example` | Editable install lost; bind-mount shadowed it | `docker compose exec tethysdash bash -c "pip install -e /workspaces/geoglows-summit-plugin-example"` |
| Ollama `pull` hangs forever | Model name typo or proxy issue | `docker compose exec ollama ollama list` to verify reachability |
| Dashboard renders blank tiles | Python error in your viz plugin | `docker compose logs -f tethysdash` to see the traceback |
| Slow first prompt | Ollama is loading the model into memory | Wait ~30s on first call; subsequent calls are fast |
