# Static site generator

Markdown → HTML using real npm packages, TypeScript, and Node APIs — no Node.js installed.

## What's happening

1. `npm install` pulls `marked` into `node_modules/` (one-time setup)
2. QuickBEAM's OXC bundler resolves imports and bundles `build.ts` + `marked` into a single script
3. The script runs on QuickJS inside a supervised BEAM process
4. `fs.readFileSync` / `fs.writeFileSync` call back to Erlang's `:file` module
5. `path.join` / `path.basename` run in pure JS (QuickBEAM's Node compat layer)

```
priv/content/*.md  →  [QuickJS + marked]  →  _site/*.html
                          ↕ Beam.call
                       [Elixir handlers]
```

## Run

```sh
npm install
mix deps.get
mix run build.exs
```

```
  hello-world.html → Hello World
  beam-vs-node.html → Why BEAM Instead of Node
  index.html → Index (2 posts)
```

Open `_site/index.html` in a browser.

## How it works

**`priv/ts/build.ts`** — TypeScript with real npm imports and Node APIs:

```typescript
import { marked } from "marked"
import fs from "node:fs"
import path from "node:path"

const files = fs.readdirSync(contentDir).filter(f => f.endsWith(".md"))
for (const file of files) {
  const html = marked.parse(body)
  fs.writeFileSync(path.join(outputDir, `${slug}.html`), page)
  console.log(`  ${slug}.html → ${meta.title}`)
}
```

**`build.exs`** — Elixir wires it together:

```elixir
{:ok, rt} = QuickBEAM.start(
  script: "priv/ts/build.ts",
  apis: [:browser, :node],
  define: %{"contentDir" => "priv/content", "outputDir" => "_site"}
)
```

## What replaces what

| Node.js ecosystem | QuickBEAM equivalent |
|-|-|
| `node` runtime | QuickJS inside BEAM |
| `npm install` | Same — real `node_modules/` |
| `tsc` / TypeScript | OXC transform (100x faster) |
| `webpack` / `esbuild` | OXC bundler (at compile time) |
| `fs`, `path`, `os` | Elixir-backed Node compat layer |
| `pm2` / process manager | OTP supervisor |
