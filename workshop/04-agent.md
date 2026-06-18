# Chapter 4 - `Agent`: role, task, dependencies

> **Goal (6 min):** understand the layer that turns "one LLM with tools"
> into "a team member with a job and upstream/downstream peers."
>
> **Suggested live demo:** build `data_agent >> viz_agent`, run it, and
> show the `<context>` block in viz_agent's prompt holding data_agent's
> output verbatim.

Library source at `repos/tethys-agents/src/tethys_agents/`.

## What it is, in one sentence

An `Agent` is **a `ReactAgent` wrapped with team metadata**: a name, a
backstory (the system prompt), a task description, expected output
shape, and a list of agents it depends on or feeds.

## Construction

```python
from tethys_agents.agent import Agent
from tethys_agents.discover import discover

data_tools = discover(["geoglows_summit_example"])

data_agent = Agent(
    name="data_fetcher",
    backstory="You fetch hydrological data using the available tools.",
    task_description="Find the river near (6.25, -75.56) and fetch its forecast.",
    task_expected_output="A handle string the next agent can use.",
    tools=data_tools,
    llm="qwen3:4b",
)
```

Inside `__init__` (`agent.py:34-57`), it constructs a `ReactAgent` with
`model=llm`, `system_prompt=backstory`, `tools=tools`. So an `Agent`
**is** a `ReactAgent` - just with structured framing.

## The `>>` operator - dependency graph DSL

```python
data_agent >> viz_agent              # data_agent runs first; viz_agent depends on it
data_agent >> viz_agent >> report    # chains - `>>` returns the right operand
```

`>>` is `__rshift__` (`agent.py:62-70`): registers the dependency in
both agents' adjacency lists. Reverse direction with `<<`.

## Context propagation

When `data_agent.run()` finishes, its output is piped to every dependent
via `receive_context` (`agent.py:149-156`). That appends to the
dependent's `self.context`. When `viz_agent.run()` later builds its
prompt via `create_prompt()`, that context appears between
`<context>...</context>` tags in viz_agent's user message - so viz_agent
literally reads what data_agent produced.

## `create_prompt()` is load-bearing

The prompt `Agent` feeds to its `ReactAgent` is **action-oriented**
(`agent.py:158-212`). It opens with:

```
USE YOUR TOOLS. You have tool-calling capability via <tool_call>
blocks. Do NOT describe what your tools would do - invoke them.
```

**Why so blunt?** The user message outweighs the system prompt in many
models' attention. A narrative template ("create the best response")
here silently overrode "call tools" instructions in the backstory - the
agent would write prose about what it *would* do instead of doing it.
This was a real workshop-debug-day bug.

## Common misconceptions

| Misconception | Reality |
|---|---|
| "An Agent is an LLM" | An Agent is *metadata + a ReactAgent*. The LLM runs inside the ReactAgent |
| "`>>` runs in parallel" | Strictly sequential. `>>` is dependency, not concurrency |
| "Backstory and task are the same" | Backstory = LLM identity (system prompt). Task = specific assignment for this run (user prompt) |
| "Context is passed once and consumed" | It accumulates - every upstream output appends to the dependent's `self.context` |
| "Agents survive across `Crew.run()` calls" | Their `context` does - call `agent.reset()` (or rebuild) between runs |

## Extension points to try

| Want to... | Touch... |
|---|---|
| Customize the action-oriented prompt | Subclass `Agent`, override `create_prompt()` |
| Transform upstream output before consumption | Override `receive_context()` to parse / filter / summarize |
| Reuse the same Agent in multiple Crews | Construct outside any `with Crew()` block, add manually with `crew.add_agent()` |
| Build a fan-out (one agent → many) | `data_agent >> [viz_agent, summary_agent, alert_agent]` |

## When to use `Agent` vs raw `ReactAgent`

| Use raw `ReactAgent` | Use `Agent` |
|---|---|
| Single role, no teammates | Multiple specialized agents collaborate |
| You drive the loop yourself | The library drives ordering |
| No dependency graph | You want `>>` for data flow |

## Try it (3 min)

Wire two agents with `>>` and watch the `<context>` block fill in.

```bash
docker compose exec tethysdash python - <<'PY'
from tethys_agents.agent import Agent
from tethys_agents.discover import discover

tools = discover(["geoglows_summit_example"])

finder = Agent(
    name="finder",
    backstory="You locate GEOGloWS rivers.",
    task_description="Find the river_id nearest to lat=6.25, lon=-75.56.",
    task_expected_output="Just the river_id on its own line.",
    tools=tools,
    llm="qwen3:4b",
)
reporter = Agent(
    name="reporter",
    backstory="You summarize hydrology results in one sentence.",
    task_description="Using the upstream finder's result, fetch the forecast and summarize the peak.",
    task_expected_output="One sentence with the peak flow.",
    tools=tools,
    llm="qwen3:4b",
)

finder >> reporter         # dependency edge - finder runs first

finder.run()               # output is auto-piped to reporter.context
print("\n--- reporter.context (what reporter will see) ---")
print(reporter.context)
PY
```

What to look for:

- `reporter.context` contains `finder`'s output verbatim, wrapped in a
  `<finder>` tag - that's exactly what will land in reporter's
  `<context>` block on its next `run()`.
- If you call `finder.run()` a second time, reporter's context **grows**
  rather than resetting (Misconception #4). Call `reporter.reset()` to
  clear it.

### Or test it end-to-end via the chat CLI

```bash
docker compose exec tethysdash tethysdash chat --user admin --runner multi
```

Then type:

> Find the river near (6.25, -75.56), then summarize its forecast in one sentence.

What to watch for in the colored output:

- The banner prints `RUNNING AGENT: data_agent`, you see data_agent's
  tool calls run, then `RUNNING AGENT: viz_agent` - that's the `>>`
  edge firing the dependency order.
- viz_agent gets data_agent's output via the `<context>` block; the CLI
  doesn't print the block, but the heredoc above shows exactly what's
  inside.

## Quick reference

| Concept | File | Lines |
|---|---|---|
| `Agent` class + constructor | `agent.py` | 8-57 |
| `>>` and `<<` operators | `agent.py` | 62-107 |
| Dependency registration | `agent.py` | 109-147 |
| Context propagation | `agent.py` | 149-156 |
| `create_prompt()` template | `agent.py` | 158-212 |
| `Agent.run()` | `agent.py` | 214-228 |

## In one paragraph

An `Agent` is a `ReactAgent` plus a role contract: name, backstory,
task, expected output, and dependency edges. Use `>>` to wire agents
into a graph; each agent's output flows into its dependents' `<context>`
block on the next run. The `create_prompt()` template is intentionally
imperative ("USE YOUR TOOLS") because the user message outweighs the
system prompt in most models' attention. Above this layer, `Crew`
schedules the graph.
