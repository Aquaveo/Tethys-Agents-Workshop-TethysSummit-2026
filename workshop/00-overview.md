# Chapter 0 - The `tethys-agents` library at a glance

> **Goal (2 min):** before we dive into each layer, see the whole
> system. Five chapters, one mental model.

## The four layers (plus the outer ring)

```
┌──────────────────────────────────────────────────────────────────┐
│  Crew              ← topology layer: orchestrates many Agents    │
│   └── Agent        ← role layer: wraps a ReactAgent with         │
│        │              backstory + task + dependencies            │
│        └── ReactAgent  ← reasoning layer: ReAct tool-use loop    │
│             └── Tool   ← capability layer: one Python function   │
└──────────────────────────────────────────────────────────────────┘
        ▲
        │
        │  outer ring: Discovery + AgentRunner Protocol
        │  (how a host application finds + drives the layers above)
```

Each layer adds **one** concern:

| Layer | One-line description | Workshop chapter |
|---|---|---|
| `Tool` | what can be called | **02** |
| `ReactAgent` | how to drive an LLM to call them | **03** |
| `Agent` | who I am, what I'm here to do, who I depend on | **04** |
| `Crew` | the team and the order of work | **05** |
| Discovery / `AgentRunner` | how the host finds plugins at runtime | **06** |

You **compose from the bottom**. Workshop participants spend 90% of
their time at the `Tool` layer; everything above orchestrates tools.

## The 30-minute reading map

| # | File | Topic | Time |
|---|---|---|---|
| 00 | `00-overview.md` | This page - the mental model | 2 min |
| 02 | `02-how-tools-work.md` | Tools: catalog, prompted use, thinking | 6 min |
| 03 | `03-react-agent.md` | ReactAgent: the ReAct loop + exits | 6 min |
| 04 | `04-agent.md` | Agent: role, task, dependencies | 6 min |
| 05 | `05-crew.md` | Crew: topological orchestration | 6 min |
| 06 | `06-discovery-and-runners.md` | Discovery + Protocol: host/plugin boundary | 4 min |

Total: **30 min** spoken. Leaves 30 min for hands-on (Chapter 01 -
`01-composing-tools.md` - drives the exercise).

## Where the source lives

All library code is at `repos/tethys-agents/src/tethys_agents/`. Every
chapter ends with a **Quick reference** table mapping concepts to
`file:lines` so you can read the actual implementation after the
workshop. The whole library is ~1,200 lines across 9 files - small
enough to read in one sitting.

## One sentence per chapter, top to bottom

- **Tools** are Python functions whose name/signature/docstring get
  serialized into the LLM's system prompt as a text catalog.
- **ReactAgent** runs the LLM in a loop, parsing `<tool_call>` XML
  blocks, executing them, feeding results back, exiting when the LLM
  writes prose without asking for another tool.
- **Agent** wraps one ReactAgent with team metadata (name, backstory,
  task, dependencies) so it can collaborate with other agents.
- **Crew** is a context-managed topological scheduler that runs many
  `Agent`s in dependency order.
- **Discovery + AgentRunner** are the two functions a host application
  uses to find your plugin's tools and runners at runtime - convention
  over configuration.
