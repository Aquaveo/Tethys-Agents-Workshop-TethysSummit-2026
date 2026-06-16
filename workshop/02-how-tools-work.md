# Chapter 2 - How tools actually work under the hood

> **Goal (6 min):** understand what happens between your Python function
> and the LLM, so the patterns in Chapter 1 stop feeling magical.
>
> **Suggested live demo:** dump the actual tool catalog (one-liner
> below), then remove a docstring and watch the LLM stop calling that
> tool.

Library source at `repos/tethys-agents/src/tethys_agents/`.

## A tool is three things

```
your function:    def fetch_forecast(river_id: str) -> str:
                      """Fetch the GEOGloWS forecast for a given river_id."""
                      return ...

what the LLM      { "name": "fetch_forecast",
sees:               "description": "Fetch the GEOGloWS forecast for a given river_id.",
                    "parameters": {"properties": {"river_id": {"type": "str"}}} }

what runs:        the original Python function, unchanged
```

The library builds that dict from `__name__`, `__doc__`, and
`__annotations__` (see `tool.py:5-25`). The LLM **only sees** the dict -
never your implementation.

## How the LLM gets the catalog

Every tool's dict is JSON-serialized and **concatenated into the system
prompt** between `<tools>...</tools>` tags (`react_agent.py:241-244`,
template at `:22-57`). There is no separate API call, no `tools=` param,
no negotiation. The model is *told* the tools exist.

Dump the exact catalog the LLM receives:

```bash
docker compose exec tethysdash python -c "
from tethys_agents.discover import discover
tools = discover(['geoglows_summit_example'])
print('\n\n'.join(t.fn_signature for t in tools))
"
```

## Why no decorator? The discovery convention

`discover()` walks `<pkg>.tools/` and auto-wraps every qualifying public
function. Rules (`discover.py`):

| Function | Becomes a tool? |
|---|---|
| Public name + type-annotated + defined in `tools/*.py` | Yes |
| Leading `_` | No (private helper) |
| Missing type annotations | No (LLM has no schema) |
| Imported from elsewhere | No (only locally-defined) |

## Prompted tool-use (the library doesn't use a "tools API")

The LLM call is three lines (`utils/completions.py:1-15`) - no `tools=`
parameter. The model returns a string; the library parses it for
`<tool_call>{...}</tool_call>` XML. Same contract for every backend.

Small models can misbehave. The library has four defensive layers - each
turns a model mistake into feedback the LLM reads next turn:

| Failure | Defense |
|---|---|
| Wrong format (markdown code fence) | Detect + inject correction + retry (`react_agent.py:287-325`) |
| Malformed JSON in `<tool_call>` | Wrap error as observation (`:132-152`) |
| Hallucinated tool name | Wrap "unknown tool, available: [...]" (`:170-188`) |
| Tool body raises | Wrap exception as observation (`:200-217`) |

## Thinking mode is the model's behavior, not the library's

`completions_create` has no thinking flag. `_strip_thinking`
(`react_agent.py:94-108`) only **hides** `<think>...</think>` from the
final answer - the model still **generates** every thinking token
(latency hit). To skip thinking entirely, prepend `/no_think` (qwen3) or
use a non-thinking model.

## Common misconceptions

| Misconception | Reality |
|---|---|
| "The LLM sees my code" | Only sees name + docstring + type annotations |
| "Adding more tools always helps" | Catalog grows; past ~10-50 tools small models drop accuracy. Use recipes |
| "I must use `@tool`" | Only for explicit registration. Discovery auto-wraps any qualifying function |
| "The library needs a model with a tools API" | No - uses prompted protocol; works on any chat-tuned LLM |
| "Stripping thinking saves latency" | No - it only hides the output. Tokens are generated regardless |

## Extension points to try

| Want to... | Touch... |
|---|---|
| Add a new tool | Drop a function in `<pkg>/tools/<anything>.py` |
| Retune when the LLM calls a tool | Edit its docstring - no restart needed |
| Compose a multi-step pipeline into one tool | Write a recipe that calls primitives (see ch.01) |
| Teach the library a new LLM dialect | `register_model_spec("mymodel", ModelSpec(...))` |

## Quick reference

| Concept | File | Lines |
|---|---|---|
| Build a tool's signature dict | `tool.py` | 5-25 |
| `@tool` decorator | `tool.py` | 89-106 |
| ReAct system prompt template | `react_agent.py` | 22-57 |
| Catalog injection into prompt | `react_agent.py` | 241-244 |
| The LLM call | `utils/completions.py` | 1-15 |
| Defensive handlers (4 failure modes) | `react_agent.py` | 110-227, 287-325 |
| Strip thinking block | `react_agent.py` | 94-108 |
| Convention-based discovery | `discover.py` | (whole file) |

## In one paragraph

A tool is a Python function whose signature, docstring, and type hints
get serialized into the system prompt as a text catalog the LLM reads.
The LLM emits `<tool_call>{...}</tool_call>` XML blocks; the library
parses them, runs the function, and feeds the result back. Same protocol
for every backend. Small-model misbehavior becomes self-corrected
feedback, not a crash. Thinking is the model's behavior - the library
only chooses whether to display it.
