# Chapter 6 - Discovery + `AgentRunner`: the host/plugin boundary

> **Goal (4 min):** understand the outer ring - the two functions a host
> application (like `tethysdash chat`) uses to find your plugin's tools
> and runners at runtime, without importing them statically.
>
> **Suggested live demo:** run `discover()` and `discover_runners()`
> from a Python shell, then show how `tethysdash chat` calls both at
> startup.

Library source at `repos/tethys-agents/src/tethys_agents/`.

## What this layer is for

The agent loop (Chapters 2-5) doesn't care where tools and runners come
from. It just receives lists. **Discovery is how the host populates
those lists** from a portal-config list of package names, without any
per-plugin glue.

```
portal_config.yml ──► AGENTS.PACKAGES = ["pkg_a", "pkg_b"]
                              │
                              ▼
         ┌────────────────────┴────────────────────┐
         │                                          │
    discover(packages)                  discover_runners(packages)
    walks <pkg>.tools                   walks <pkg>.agent
         │                                          │
         ▼                                          ▼
    list[Tool]                          {"single": cls, "multi": cls}
         │                                          │
         ▼                                          ▼
    fed to ReactAgent                    instantiated by harness
```

## `discover(packages)` - find tools

`discover.py`. For each package: import `<pkg>.tools`, walk every
submodule, scan public type-annotated functions defined in the tree,
auto-wrap them with `@tool`, deduplicate by `id(fn)`.

```python
from tethys_agents.discover import discover
tools = discover(["geoglows_summit_example", "tethysapp.tethysdash"])
# Tools from both packages, deduplicated. No @tool decorator needed.
```

## `discover_runners(packages)` - find agent topologies

Same pattern, different submodule. Imports `<pkg>.agent` and reads its
`RUNNERS` dict:

```python
# In geoglows_summit_example/agent/__init__.py:
RUNNERS = {"single": _SingleRunner, "multi": _CrewRunner}

# In the host:
from tethys_agents.runner import discover_runners
runners = discover_runners(["geoglows_summit_example"])
chosen  = runners["multi"](model="qwen3:8b", dashboard_tool_packages=[...])
chosen.run_turn("show me the forecast")
```

## The `AgentRunner` Protocol - three methods

`runner.py:39-59`. The entire host/plugin contract:

```python
@runtime_checkable
class AgentRunner(Protocol):
    def run_turn(self, user_msg: str) -> None: ...
    def reset(self) -> None: ...
    def describe(self) -> str: ...
```

A plugin can implement this **by duck typing** - no inheritance, no
import of `tethys-agents` required.

## The boundary inversion (why this matters)

| The host knows | The plugin knows |
|---|---|
| Django setup, the active user/dashboard | Domain (rivers, forecasts, IDEAM stations) |
| Readline + history persistence | Tool implementations |
| The 3-method Protocol | Agent backstories, ReactAgent vs Crew choice |
| Nothing about hydrology | Nothing about Django |

Same harness drives your plugin today, a different plugin tomorrow.

## Failure-mode softening

Both discoverers raise on missing **parent** package (operator typo) but
silently skip missing **submodule** - so one `AGENTS.PACKAGES` list can
contain tools-only packages alongside tools+runners packages.

| `ModuleNotFoundError.name` | Meaning | Behavior |
|---|---|---|
| `"<pkg>"` | Parent package missing | Re-raise (operator bug) |
| `"<pkg>.tools"` or `"<pkg>.agent"` | Just no submodule | Silently skip |

## Common misconceptions

| Misconception | Reality |
|---|---|
| "I need to register tools/runners with the library" | No - just put them at the convention path |
| "Plugins must import `tethys-agents`" | No - `AgentRunner` is duck-typed; the library never appears in the plugin's imports |
| "`AGENTS.PACKAGES` is for runner packages only" | Unified list. Each layer picks the submodule it needs |
| "If `<pkg>.agent` doesn't exist, the harness errors" | Silently skipped. Only the *parent* package missing triggers an error |
| "Two packages can't both contribute a `RUNNERS['single']`" | They can be listed; first-listed wins, others log WARNING |

## Extension points to try

| Want to... | Touch... |
|---|---|
| Write a runner that doesn't use ReactAgent at all | Implement the 3 Protocol methods directly - call any LLM however you want |
| Add a tools-only package (no agents) | Just add to `AGENTS.PACKAGES`; missing `.agent` is fine |
| Build a different host (e.g. a Slack bot) | Reuse `discover_runners()`; supply your own input loop in place of readline |
| Override the default runner per call | Pass `--runner <name>` to `tethysdash chat` |

## Quick reference

| Concept | File | Lines |
|---|---|---|
| `discover()` - find tools | `discover.py` | 44-146 |
| Submodule walk + dedup | `discover.py` | 89-146 |
| Missing-submodule softening | `discover.py` | 72-87 |
| `discover_runners()` - find runners | `runner.py` | 62-108 |
| Missing-submodule softening | `runner.py` | 83-94 |
| `AgentRunner` Protocol | `runner.py` | 39-59 |

## In one paragraph

The library's outer ring is two convention-based functions:
`discover()` walks `<pkg>.tools` to harvest tool functions,
`discover_runners()` walks `<pkg>.agent` to harvest `RUNNERS` dicts. The
host and plugin share only the 3-method `AgentRunner` Protocol -
`run_turn`, `reset`, `describe`. Missing submodules are skipped
silently; missing parent packages still raise. That's how one unified
`AGENTS.PACKAGES` list serves every plugin role in the portal config.
