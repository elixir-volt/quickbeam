# OXC

Elixir bindings for the [OXC](https://oxc.rs) JavaScript toolchain via Rust NIFs.

Parse, transform, and minify JavaScript/TypeScript at native speed.

## Features

- **Parse** JS/TS/JSX/TSX into ESTree AST (maps with atom keys)
- **Transform** TypeScript → JavaScript, JSX → `createElement`/`jsx` calls
- **Minify** with dead code elimination, constant folding, and variable mangling
- **Bundle** multiple TS/JS modules into a single IIFE with dependency resolution
- **Walk/Collect** helpers for AST traversal and node filtering
- **Import extraction** — fast NIF-level import specifier extraction

## Installation

```elixir
def deps do
  [
    {:oxc, "~> 0.3.0"}
  ]
end
```

Requires a Rust toolchain (`rustup` recommended). The NIF compiles automatically on `mix compile`.

## Usage

### Parse

```elixir
{:ok, ast} = OXC.parse("const x = 1 + 2", "test.js")
ast.type
# "Program"

[stmt] = ast.body
stmt.expression
# %{type: "BinaryExpression", operator: "+", left: %{value: 1}, right: %{value: 2}}
```

File extension determines the dialect — `.js`, `.jsx`, `.ts`, `.tsx`:

```elixir
{:ok, ast} = OXC.parse("const x: number = 42", "test.ts")
{:ok, ast} = OXC.parse("<App />", "component.tsx")
```

### Transform

Strip TypeScript types and transform JSX:

```elixir
{:ok, js} = OXC.transform("const x: number = 42", "test.ts")
# "const x = 42;\n"

{:ok, js} = OXC.transform("<App />", "app.tsx")
# Uses automatic JSX runtime by default

{:ok, js} = OXC.transform("<App />", "app.jsx", jsx: :classic)
# Uses React.createElement
```

With source maps:

```elixir
{:ok, %{code: js, sourcemap: map}} = OXC.transform(code, "app.ts", sourcemap: true)
```

Target specific environments:

```elixir
{:ok, js} = OXC.transform("const x = a ?? b", "test.js", target: "es2019")
# Nullish coalescing lowered to ternary
```

Custom JSX import source (Vue, Preact, etc.):

```elixir
{:ok, js} = OXC.transform("<div />", "app.jsx", import_source: "vue")
# Imports from vue/jsx-runtime instead of react/jsx-runtime
```

### Minify

```elixir
{:ok, min} = OXC.minify("const x = 1 + 2; console.log(x);", "test.js")
# Constants folded, whitespace removed, variables mangled

{:ok, min} = OXC.minify(code, "test.js", mangle: false)
# Compress without renaming variables
```

### Import Extraction

Fast NIF-level extraction of import specifiers — skips full AST serialization:

```elixir
{:ok, imports} = OXC.imports("import { ref } from 'vue'\nimport { h } from 'preact'", "test.ts")
# ["vue", "preact"]
```

Type-only imports are excluded automatically:

```elixir
{:ok, imports} = OXC.imports("import type { Ref } from 'vue'\nimport { ref } from 'vue'", "test.ts")
# ["vue"]
```

### Validate

Fast syntax check without building an AST:

```elixir
OXC.valid?("const x = 1", "test.js")
# true

OXC.valid?("const = ;", "bad.js")
# false
```

### AST Traversal

```elixir
{:ok, ast} = OXC.parse("import a from 'a'; import b from 'b'; const x = 1;", "test.js")

# Walk every node
OXC.walk(ast, fn
  %{type: "Identifier", name: name} -> IO.puts(name)
  _ -> :ok
end)

# Collect specific nodes
imports = OXC.collect(ast, fn
  %{type: "ImportDeclaration"} = node -> {:keep, node}
  _ -> :skip
end)
# [%{type: "ImportDeclaration", source: %{value: "a"}, ...}, ...]
```

### Bundle

Bundle multiple TypeScript/JavaScript modules into a single IIFE script.
Resolves import dependencies, topologically sorts, strips `import`/`export` syntax:

```elixir
files = [
  {"event.ts", "export class Event { type: string; constructor(t: string) { this.type = t } }"},
  {"target.ts", "import { Event } from './event'\nexport class Target extends Event {}"}
]

{:ok, js} = OXC.bundle(files)
# (() => { class Event { ... } class Target extends Event { } })();
```

Options:

```elixir
# Minify with tree-shaking and variable mangling
{:ok, js} = OXC.bundle(files, minify: true)

# Compile-time replacements (like esbuild/Bun define)
{:ok, js} = OXC.bundle(files, define: %{"process.env.NODE_ENV" => ~s("production")})

# Source maps
{:ok, %{code: js, sourcemap: map}} = OXC.bundle(files, sourcemap: true)

# Remove console.* calls
{:ok, js} = OXC.bundle(files, minify: true, drop_console: true)

# Target-specific downleveling
{:ok, js} = OXC.bundle(files, target: "es2020")

# Banner and footer
{:ok, js} = OXC.bundle(files, banner: "/* MIT */", footer: "/* v1.0 */")
```

### Bang Variants

All functions have bang variants that raise on error:

```elixir
ast = OXC.parse!("const x = 1", "test.js")
js = OXC.transform!("const x: number = 42", "test.ts")
min = OXC.minify!("const x = 1 + 2;", "test.js")
imports = OXC.imports!("import { ref } from 'vue'", "test.ts")
```

## How It Works

OXC is a collection of high-performance JavaScript tools written in Rust.
This library wraps `oxc_parser`, `oxc_transformer`, `oxc_minifier`,
`oxc_transformer_plugins`, and `oxc_codegen` via [Rustler](https://github.com/rusterlium/rustler) NIFs.

All NIF calls run on the dirty CPU scheduler so they don't block the BEAM.
The parser produces JSON via OXC's ESTree serializer, which is then
converted to atom-keyed Elixir maps in the NIF — no JSON library needed
on the Elixir side.

## License

MIT
