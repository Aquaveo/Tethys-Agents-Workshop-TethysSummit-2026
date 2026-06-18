# Chapter 1 - Composing tools from primitives

> **Goal:** by the end of this chapter you'll have written a Python
> function, saved the file, and watched the chat agent call your new
> function as a tool on its very next turn - no registration step.

## What's a "tool" in this stack

The chat agent is a `ReactAgent` (single mode) or a `Crew` (multi mode)
that calls Python functions during a conversation. Those functions are
called **tools**. Each tool has:

- A **name** (the function's `__name__`)
- A **signature** (the type-annotated parameters)
- A **description** (the function's docstring - this is what the LLM
  reads to decide whether to call it)

The LLM never sees your function's *implementation*. It sees the name,
signature, and docstring. The docstring is your contract with the LLM.

## The primitives - your starting toolkit

The plugin ships with 6 **primitives** in
`geoglows_summit_example/tools/primitives.py`. Each wraps one data source
or one transformation. Don't edit this file - `import` from it.

| Primitive | Inputs | Returns |
|---|---|---|
| `find_river_id_near_location(lat, lon)` | float, float | `"Nearest GEOGloWS river to (...) is river_id N."` |
| `fetch_retrospective(river_id)` | str | `"... Handle: retro:<river_id>"` |
| `fetch_forecast(river_id)` | str | `"... Handle: forecast:<river_id>"` |
| `fetch_forecast_ensembles(river_id)` | str | `"... Handle: ensembles:<river_id>"` |
| `fetch_observed_discharge(station_id)` | str | `"... Handle: observed:<station_id>"` |
| `bias_correct_forecast(ens, retro, obs)` | str, str, str | `"... Handle: bias:<river_id>:<station_id>"` |

A few things to notice:

- **Every primitive returns a string**, not raw data. The LLM only ever
  sees strings - handles like `retro:610217883` are opaque tokens it can
  pipe into the next primitive.
- **Most strings end in `Handle: <type>:<key>`**. The handle is the
  pointer to the cached parquet on disk. When you compose primitives,
  you extract the handle from one's output and pass it into the next.
- **Cache handles are cheap to re-fetch**. The primitives are
  cache-aware - calling `fetch_retrospective` twice for the same river
  hits a parquet on disk the second time, not the GEOGloWS REST API.

## The discovery convention

Open `geoglows_summit_example/tools/recipes.py` - that's the file you'll
edit. The plugin's discovery layer walks every public function in any
file under `tools/` and auto-registers it as a tool. The rules:

| Function attribute | What discover does |
|---|---|
| Public name (no leading `_`) | ✓ candidate for registration |
| Has type-annotated parameters | ✓ schema generation works |
| Has a docstring | ✓ LLM has guidance on when to call it |
| Defined in `tools/*.py` (any submodule) | ✓ filtered to this package only |
| Starts with `_` | ✗ skipped - treated as private helper |
| Imported into the file from elsewhere | ✗ skipped - only locally-defined |

No decorator, no registry append, no entry-point. Save the file → the
chat agent's next round sees your function as a tool.

## Worked example 1 - a trivial wrapper

The simplest "new tool" possible: a friendlier interface around one
primitive. From `recipes.py`:

```python
# Hardcoded internally - the docstring deliberately does NOT mention the
# literal river_id. Small models copy concrete numbers from docstrings
# into other tool calls verbatim.
_CARACOLI_RIVER_ID = "610217883"


def forecast_for_caracoli() -> str:
    """Fetch the GEOGloWS forecast for the workshop's reference river, Caracoli.

    Use this ONLY when the user explicitly names Caracoli or asks for "the
    workshop's reference river". For ANY other river or location, do NOT
    call this - use find_river_id_near_location + fetch_forecast (or
    bias_correction_chain) instead.
    """
    return fetch_forecast(_CARACOLI_RIVER_ID)
```

Three things to notice:

- **Zero-arg wrapper collapses three rounds into one.** Without this tool
  the LLM would have to call `find_river_id_near_location`, parse the
  river_id out of prose, then call `fetch_forecast`.
- **The literal id is in a constant, not the docstring.** Small models
  often copy concrete numbers from docstrings into other tool calls
  ("oh, river_id is usually 610217883"). Hide the value, expose only the
  intent.
- **The exclusion clause matters.** Without `Use this ONLY when ... do
  NOT call this for any other river`, a 4B model will sometimes fire
  this for "show me the forecast for the Amazon" - the function name
  matches the topic and a small model can't tell that "Caracoli" was a
  proper name, not a synonym for "forecast".

**Try it.** In the chat REPL (`docker compose exec tethysdash tethysdash chat
--user admin --runner single`), type:

> Show me the forecast for Caracoli.

What to watch in the colored trace: a single `<tool_call>` for
`forecast_for_caracoli` (zero args), one observation, then prose. No
`find_river_id_near_location` call - that's the value of the wrapper.

## Worked example 2 - chaining primitives

The bias-correction pipeline normally takes 5 tool calls - find river,
fetch ensembles, fetch retro, fetch observed, run bias correction. A
recipe collapses it into one:

```python
def bias_correction_chain(
    lat: float, lon: float, station_id: str,
) -> str:
    """Full bias-correction pipeline from a coordinate + IDEAM station id."""
    river_id = _parse_river_id(find_river_id_near_location(lat, lon))

    # Short-circuit on the first primitive that returns an error string
    # (no "Handle:" prefix). See the "Errors short-circuit" bullet below
    # for why this matters.
    ensembles_out = fetch_forecast_ensembles(river_id)
    if "Handle:" not in ensembles_out:
        return ensembles_out
    retrospective_out = fetch_retrospective(river_id)
    if "Handle:" not in retrospective_out:
        return retrospective_out
    observed_out = fetch_observed_discharge(station_id)
    if "Handle:" not in observed_out:
        return observed_out

    return bias_correct_forecast(
        _extract_handle(ensembles_out),
        _extract_handle(retrospective_out),
        _extract_handle(observed_out),
    )
```

Two things this teaches:

- **Primitives return prose; helpers extract structure.** `_parse_river_id`
  and `_extract_handle` (private helpers, leading underscore) parse the
  primitives' human-readable strings into the bare values the next
  primitive needs. In production you'd want primitives to return
  structured data alongside the prose; for the workshop, string parsing
  keeps the primitives readable to the LLM.
- **Errors short-circuit at the recipe layer.** Every primitive returns
  either a string ending in `"Handle: ..."` (success) or a string starting
  with `"Error ..."` (failure). The recipe checks for `"Handle:"` after
  each call and returns the error string unchanged as soon as one shows
  up. Without this guard, a bad upstream output would flow through
  `_extract_handle` (which intentionally passes errors through) into
  `bias_correct_forecast`, where `parse_handle`'s colon-split mangles the
  error sentence into a confusing nested "river_id mismatch" error two
  layers downstream - a real bug we hit during workshop dev. The LLM
  reads the clean upstream error and can retry sensibly.

**Try it.** In the chat REPL, type:

> Run the bias-correction pipeline for coordinates 6.25, -75.56 using IDEAM station 0026177030.

What to watch: a SINGLE `<tool_call>` for `bias_correction_chain`. Without
this recipe the agent would emit four separate tool calls
(`find_river_id_near_location` → `fetch_forecast_ensembles` →
`fetch_retrospective` → `fetch_observed_discharge` → `bias_correct_forecast`)
- five rounds collapse into one.

## Your exercise

At the bottom of `recipes.py` you'll find:

```python
def my_workshop_tool(river_id: str) -> str:
    """TODO: replace this docstring with a clear description of YOUR tool."""
    return "TODO: implement my_workshop_tool"
```

Pick one of these directions (or invent your own):

| Idea | Composition | Prompt to try once you've implemented it |
|---|---|---|
| `compare_forecasts(river_id, station_id)` | fetch raw + bias-corrected, report median delta | *"How different is the bias-corrected forecast from the raw one for river 610217883 against station 0026177030?"* |
| `flow_status_at(river_id, station_id)` | retro + current forecast, return HIGH/NORMAL/LOW vs. historical | *"Is river 610217883 running high, normal, or low right now compared to history? Use station 0026177030."* |
| `multi_station_observed(station_ids: str)` | accept a comma-separated list of station ids, fetch each, return a one-line summary per | *"Show me observed discharge for stations 0026177030, 0026197040, and 0026200030."* |
| `quick_overview(lat, lon, station_id)` | retro + bias + observed in one tool, return short summary | *"Give me a quick overview of the river near 6.25, -75.56 using station 0026177030."* |

Two rules to follow:

1. **Make the docstring specific.** "Tool to do stuff" is a bad
   docstring - the LLM won't know when to use it. "Fetch the latest
   forecast and compare it to the historical median, return whether the
   river is HIGH/NORMAL/LOW" is a good docstring.

2. **Keep the return short.** Under ~200 tokens. Long returns burn the
   chat context budget on every subsequent round.

## Test your new tool

After saving `recipes.py`, two ways to confirm the tool is registered:

**1. Static check** - list every tool the discovery layer finds:

```bash
docker compose exec tethysdash python -c "
from tethys_agents.discover import discover
print(sorted(t.name for t in discover(['geoglows_summit_example'])))
"
```

You should see your tool name in the list.

**2. Live check** - call your tool through the chat agent:

```bash
docker compose exec tethysdash tethysdash chat --user admin --runner single
```

Type one of the "Prompt to try" rows from the table above (or your own,
phrased around your tool's docstring). Watch the colored trace - you should
see your tool's name in a `<tool_call>` block, NOT a chain of primitive
calls. If the agent emits primitives instead, the docstring isn't
specific enough - rewrite it and try again.

## Common mistakes

| Symptom | Likely cause | Fix |
|---|---|---|
| Tool doesn't appear in the discover() list | Missing type annotations on params | Add `: str` / `: float` to every parameter |
| Tool appears but agent never calls it | Vague docstring | Rewrite docstring with specific input/output description |
| Agent calls your tool, tool returns "TODO" | Forgot to implement | Replace the `return "TODO: ..."` line |
| Edit doesn't seem to take effect | Django dev server didn't reload | Save the file again, or `docker compose restart tethysdash` |
| `NameError: find_river_id_near_location` | Forgot the import at the top of recipes.py | The top of the file already imports the 6 primitives - make sure you didn't accidentally delete that block |
| Tool raises `int(...)` error | Passed a primitive's full string instead of an extracted handle / id | Use `_extract_handle()` or `_parse_river_id()` first |

## What you've learned

- Tools are plain Python functions discovered by convention
- Handles are opaque tokens that chain primitives without ever
  serializing raw data into the chat context
- Recipes (composed tools) collapse multi-step LLM plans into single
  tool calls - better latency, better reliability on small models
- Private helpers (leading underscore) handle the prose-parsing details
  so the public surface stays small and predictable

In the next chapter we'll do the same exercise for **visualization plugins** -
write a small Plotly subclass under `viz/`, watch it appear as a registered
intake source, and have the agent place it on a dashboard tile.
