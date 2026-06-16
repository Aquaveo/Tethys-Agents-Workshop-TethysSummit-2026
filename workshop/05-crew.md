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
