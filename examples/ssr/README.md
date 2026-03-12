# SSR with Preact

Server-side rendering using Preact components, a pool of JS runtimes,
and QuickBEAM's native DOM — no Node.js, no `renderToString`.

## What's happening

1. `mix npm.install preact` fetches Preact into `node_modules/`
2. OXC transforms JSX and bundles `app.jsx` + Preact into a single script at startup
3. A `QuickBEAM.Pool` of 4 runtimes is initialized with the bundle
4. On each request, a runtime is checked out from the pool
5. Preact's `render()` writes into the native DOM (lexbor, a C library)
6. Elixir reads the DOM with `dom_text/2` to extract the page title
7. `document.body.innerHTML` serializes the body HTML
8. The runtime is reset and returned to the pool

```
                     ┌──────────────────────────────────────┐
  HTTP request ───→  │  QuickBEAM.Pool (4 runtimes)         │
                     │                                      │
                     │  ┌─ QuickJS ──────────────────────┐  │
                     │  │  Preact h() → render()          │  │
                     │  │  ↓                              │  │
                     │  │  Native DOM (lexbor)            │  │
                     │  └─────────────┬──────────────────┘  │
                     └────────────────┼─────────────────────┘
                                      │
          Elixir reads DOM directly ──┘
          dom_text(rt, "h1") → "Blog"
          eval(rt, "document.body.innerHTML") → "<div>..."
```

## Run

```sh
mix deps.get
mix npm.install preact
mix run run.exs
```

Open http://localhost:4000

## Test

```sh
mix test
```

## Key features demonstrated

- **Native DOM** — Preact renders into a real DOM tree (lexbor), not strings
- **Elixir DOM access** — `dom_text`, `dom_find`, `dom_find_all` read the live DOM without JS execution
- **Pool** — `NimblePool` of runtimes for concurrent rendering with automatic reset
- **npm packages** — `mix npm.install`, resolved and bundled by OXC
- **Zero Node.js** — no `node`, no `npx`, no build step
