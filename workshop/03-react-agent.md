# Chapter 3 - `ReactAgent`: driving the tool-use loop

> **Goal (6 min):** understand the single piece of code that turns "an
> LLM" into "an LLM that calls your tools in a loop until done."
>
> **Suggested live demo:** run a 1-tool agent, then print `agent.trace`
> to show the round-by-round timeline.

Library source at `repos/tethys-agents/src/tethys_agents/`.

## What it is, in one sentence

A `ReactAgent` is **a deterministic state machine wrapped around an
LLM**. It calls the model, looks for tool-call blocks, runs them, feeds
the results back, and exits when the model writes prose without asking
for more tools.

## Construction

```python
from tethys_agents.react_agent import ReactAgent
from tethys_agents.discover import discover

tools = discover(["geoglows_summit_example"])
agent = ReactAgent(
    tools=tools,
    model="qwen3:8b",
    system_prompt="You are a hydrology assistant.",
)
answer = agent.run(user_msg="show me the Caracoli forecast")
```

That's the entire API at this layer. Everything else happens inside
`agent.run()`.

## The loop in 5 steps

`react_agent.py:229-369`. Pseudocode:

```python
for round_idx in range(max_rounds):                      # default 10
    completion = call_llm(chat_history, model)           # 1. ask LLM
    cleaned    = self._strip_thinking(completion)        # 2. clean output

    if model_spec.response_tag and <response> found:     # 3a. explicit-exit
        return response.content

    tool_calls = extract <tool_call> blocks
    if not tool_calls and cleaned.strip():               # 3b. implicit-exit
        return cleaned.strip()

    observations = process_tool_calls(tool_calls)        # 4. run tools
    append_to_history(observations)                       # 5. feed back, loop
```

## Two exit paths, one defensive retry

| Path | Fires when | Used by |
|---|---|---|
| **`<response>` tag** | Model emits explicit final-answer wrapper | Strict ReAct-trained models (rare) |
| **Text + no tool_call** | Model wrote prose, didn't call anything | qwen3, llama, gpt, claude - almost everyone |

There's also a **format-slip rescue** (`react_agent.py:287-325`): if
the model "exits" with text that looks like a tool call in the wrong
format (markdown fence, JSON `tool_calls` array), the loop injects a
format correction and retries the round instead of exiting.

## `ModelSpec` - per-model output dialects

`model_specs.py`. Different models emit different exit signals
(qwen3 wraps reasoning in `<think>`, llama3.2 doesn't, etc.). The
registry prefix-matches model names to specs so `ReactAgent` knows what
to expect:

```python
@dataclass(frozen=True)
class ModelSpec:
    thinking_tag: Optional[str] = None    # "think" for qwen3
    response_tag: Optional[str] = None    # "response" only if trained on it
    tool_call_tag: str = "tool_call"
    strip_thinking: bool = True
```

## The trace - your debug + UI feed

After every `agent.run()`, `agent.trace` is an ordered list of every
round, tool call, and observation. The host renders it as a timeline:

```python
for entry in agent.trace:
    print(entry["type"], entry.get("tool") or entry.get("text", "")[:60])
# user        show me the Caracoli forecast
# tool_call   find_river_id_near_location
# tool_call   fetch_forecast
# answer      The Caracoli forecast peaks at 142 m³/s on Tuesday...
```

## Common misconceptions

| Misconception | Reality |
|---|---|
| "The library handles the LLM" | It handles the *loop*. The LLM still has to follow the XML protocol from prompt alone |
| "`max_rounds` is a thinking-budget knob" | It's a runaway guard. Setting it low truncates legitimate work |
| "The `<response>` exit is the main path" | Almost no model uses it. Default exit is "wrote prose, no tool_call" |
| "Unknown models won't work" | They get `DEFAULT_SPEC` (assumes strict `<response>`); usually still works, may run extra rounds |
| "If a tool errors, the agent crashes" | Errors are wrapped as observations; the model self-corrects |

## Extension points to try

| Want to... | Touch... |
|---|---|
| Build a UI for the round-by-round timeline | Render `agent.trace` after each `run()` |
| Teach the library a new model dialect | `register_model_spec("name", ModelSpec(...))` |
| Cap LLM round-trips for a quick demo | `agent.run(user_msg, max_rounds=3)` |
| Override the system prompt entirely | Construct with your own `system_prompt=...` |

## Quick reference

| Concept | File | Lines |
|---|---|---|
| `ReactAgent` class + constructor | `react_agent.py` | 60-88 |
| ReAct system prompt template | `react_agent.py` | 22-57 |
| The loop | `react_agent.py` | 229-369 |
| `_strip_thinking` | `react_agent.py` | 94-108 |
| Exit paths | `react_agent.py` | 262-336 |
| Format-slip rescue | `react_agent.py` | 287-325 |
| Defensive tool-call handlers | `react_agent.py` | 110-227 |
| Trace entries | `react_agent.py` | 88, 220, 332, 368 |
| `ModelSpec` + registry | `model_specs.py` | (whole file) |
| LLM call (3 lines) | `utils/completions.py` | 1-15 |

## In one paragraph

A `ReactAgent` runs an LLM in a loop: call the model, strip private
reasoning, check for a final answer (either `<response>` tag or "text
without tool_call"), otherwise run `<tool_call>` blocks and feed
observations back. Per-model output quirks live in `ModelSpec`; per-run
history lives in `agent.trace`. This is the only layer that talks to the
LLM - everything above just composes ReactAgents.
