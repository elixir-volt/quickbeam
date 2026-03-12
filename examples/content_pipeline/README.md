# Content pipeline

Three supervised JS runtimes forming a markdown processing pipeline.

```
post → [parser] ──→ [analyzer] ──→ [enricher] ──→ result
        marked        native DOM      spam check
        (npm)         querySelectorAll  timestamps
```

## What's happening

1. **Parser** — converts markdown to HTML using [marked](https://marked.js.org) (npm package, bundled by OXC)
2. **Analyzer** — renders HTML into the native DOM (lexbor), then uses `querySelectorAll` to extract headings, links, and code blocks with their languages
3. **Enricher** — runs spam detection and adds metadata

Each stage is a supervised BEAM process. Kill any one — the supervisor restarts it, the others keep running.

## Run

```sh
mix deps.get
mix npm.install marked
mix run run.exs
```

```
1 | Getting Started with QuickBEAM
  33 words · 1 min read
  headings: ["Installation", "Quick start"]
  links: 2 · code blocks: 2

2 [SPAM] | Buy Now! Free Money!!!
  12 words · 1 min read
  headings: []
  links: 0 · code blocks: 0

3 | BEAM vs Node.js
  15 words · 1 min read
  headings: []
  links: 0 · code blocks: 0
```

## Test

```sh
mix test
```

## Key features demonstrated

- **npm packages** — `mix npm.install marked`, auto-bundled by OXC at startup
- **Native DOM** — the analyzer renders HTML into lexbor and queries it with `querySelectorAll`, not regex
- **Supervised pipeline** — three runtimes as OTP children, message passing via `Beam.callSync`
- **Crash isolation** — kill a stage, supervisor restarts it, others keep running
- **BEAM message routing** — JS runtimes don't know about each other; a shared `forward` handler routes by atom name
