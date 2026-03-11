---
title: Why BEAM Instead of Node
date: 2025-02-01
---

## The pitch

Run your JavaScript like Erlang runs its processes:

1. **Isolated** — each runtime is a GenServer with its own heap
2. **Supervised** — crash one, restart it, others keep running
3. **Observable** — `:telemetry`, `:observer`, all the BEAM tools work
4. **Zero-copy** — strings pass between JS and Erlang without copying

## What you keep

- Your npm packages (bundled by OXC, not webpack)
- Your TypeScript (compiled by OXC, not tsc)
- The Node API surface (`fs`, `path`, `process`, `os`)

## What you gain

- No `node_modules` in production (bundled at compile time)
- No event loop starvation — the BEAM schedules fairly
- Pattern matching on JS results from Elixir
- Hot code reloading through standard OTP releases
