# Chapter 5 - `Crew`: topological orchestration

> **Goal (6 min):** understand the scheduler that turns a graph of
> `Agent`s into a deterministic execution order.
>
> **Suggested live demo:** build a 3-agent crew with a diamond
> dependency (A → B and A → C → D), run it, and trace the execution
> order printed by `fancy_print`.

Library source at `repos/tethys-agents/src/tethys_agents/`.

## What it is, in one sentence

A `Crew` is **a registry + topological scheduler** for `Agent`
instances. It collects every `Agent` instantiated inside its `with`
block, then runs them in dependency order.

## Usage shape

```python
from tethys_agents.crew import Crew
from tethys_agents.agent import Agent

with Crew() as crew:
    data_agent = Agent(name="data_fetcher",   ..., tools=data_tools)
    viz_agent  = Agent(name="visualizer",     ..., tools=dashboard_tools)
    data_agent >> viz_agent                    # establish dependency

crew.run()                                     # topo-sort → run in order
```

`crew.run()` calls each `Agent.run()` in turn. Output propagates to
dependents' `<context>` automatically (Chapter 4).

## How registration works - the ambient-context trick

`Crew.__enter__` sets a **class-level** variable:

```python
def __enter__(self):
    Crew.current_crew = self
    return self
```

Inside `Agent.__init__`, the last line is `Crew.register_agent(self)` -
which checks `Crew.current_crew` and appends if set. Same pattern as
Flask's `current_app` and Django's request locals. Cleaner than
threading a `Crew` reference through every constructor.

## Topological sort (Kahn's algorithm)

`crew.py:66-95`. Quick version:

```python
in_degree = {agent: len(agent.dependencies) for agent in self.agents}
queue = deque([a for a in self.agents if in_degree[a] == 0])  # roots
sorted_agents = []
while queue:
    current = queue.popleft()
    sorted_agents.append(current)
    for dep in current.dependents:
        in_degree[dep] -= 1
        if in_degree[dep] == 0:
            queue.append(dep)

if len(sorted_agents) != len(self.agents):
    raise ValueError("Circular dependencies detected")
```

The cycle detector is the `len != len` check - if any agent never hit
`in_degree == 0`, it's part of a cycle.

## Common misconceptions

| Misconception | Reality |
|---|---|
| "`>>` runs in parallel" | Strictly sequential. `>>` is dependency, not concurrency |
| "Crew retries failed agents" | If an agent raises, the whole run stops |
| "Crew keeps state across `run()` calls" | Each invocation re-runs every agent from scratch (but `agent.context` persists - see ch.04) |
| "Crew dedupes agents by name" | Two `Agent` instances with the same name are two separate nodes |
| "I can instantiate Agents outside the `with` block and have them join" | No - the ambient-context registration only fires inside `__enter__/__exit__`. Use `crew.add_agent()` for that |

## Extension points to try

| Want to... | Touch... |
|---|---|
| Add retry-on-error | Subclass `Crew`, override `run()`: try/except per agent, requeue on transient errors |
| Parallel-execute independent branches | Subclass `Crew` using `concurrent.futures` to run agents whose dependencies are all complete |
| Capture every agent's trace for analysis | After `crew.run()`, walk `agent.react_agent.trace` for each agent in the crew |
| Build a different graph DSL | Skip `>>` entirely; call `agent.add_dependency()` directly |

## Try it (3 min)

Build a 2-agent crew, watch it topo-sort itself, then add a cycle and
watch it fail loudly.

```bash
docker compose exec tethysdash python - <<'PY'
from tethys_agents.crew import Crew
from tethys_agents.agent import Agent
from tethys_agents.discover import discover

tools = discover(["geoglows_summit_example"])

with Crew() as crew:
    a = Agent(name="finder",   backstory="You find rivers.",
              task_description="Find river near (6.25, -75.56).",
              task_expected_output="Just the river_id.",
              tools=tools, llm="qwen3:4b")
    b = Agent(name="reporter", backstory="You summarize forecasts.",
              task_description="Fetch + summarize the forecast for the upstream river_id.",
              task_expected_output="One sentence.",
              tools=tools, llm="qwen3:4b")
    a >> b

print("Registered:", [agent.name for agent in crew.agents])
print("Run order:", [agent.name for agent in crew._topological_sort()])

# Now uncomment the next line to introduce a cycle and re-run topo-sort:
# b >> a    # cycle: a -> b -> a
# crew._topological_sort()   # raises ValueError("Circular dependencies detected")
PY
```

What to look for:

- `crew.agents` already lists both - they self-registered via
  `Crew.current_crew` (the ambient-context trick) without you ever
  passing `crew` to either constructor.
- `_topological_sort()` returns `[finder, reporter]` because `b` depends
  on `a`.
- Uncomment the last two lines: the cycle check (`len != len` in Kahn's
  algorithm) catches it and raises before any agent runs.

### Or test it end-to-end via the chat CLI

```bash
docker compose exec tethysdash tethysdash chat --user admin --runner multi
```

Then type any prompt that needs data + a tile, e.g.:

> Find the river near (6.25, -75.56), fetch its forecast, and place a tile on the dashboard.

What to watch for in the colored output:

- `RUNNING AGENT: data_agent` always prints before `RUNNING AGENT:
  viz_agent`, no matter how you word the prompt - that's the
  topological sort deciding the order, not the LLM.
- Re-prompt with the order intentionally inverted ("place a tile, then
  fetch the data") - the order on screen stays the same. Dependency
  edges trump prompt phrasing.
- The cycle-detection demo stays heredoc-only; the CLI never builds a
  cycle on its own.

## Quick reference

| Concept | File | Lines |
|---|---|---|
| `Crew` class + context-manager protocol | `crew.py` | 8-44 |
| `add_agent` / `register_agent` | `crew.py` | 46-64 |
| Topological sort + cycle detection | `crew.py` | 66-95 |
| `crew.run()` - sequential execution | `crew.py` | 97-105 |

## In one paragraph

A `Crew` is a context-managed collector: any `Agent` constructed inside
the `with Crew()` block registers itself via the ambient
`Crew.current_crew` class variable. `crew.run()` topo-sorts the agents
using Kahn's algorithm (with a cycle detector) and runs them
sequentially. Output flows along `>>` edges automatically. It is not
parallel, not retry-aware, not stateful - three knobs you'd add when
moving past the workshop.
