# Elixir API and DSL

QuickBEAM-ng is intended to feel like an Elixir library first: runtimes are
started from keyword options, host APIs are ordinary Elixir modules, and embedded
JavaScript can be validated at Elixir compile time.

## Runtime presets

Use `QuickBEAM.sandbox/2` when you want inspectable options:

```elixir
opts = QuickBEAM.sandbox(:strict, memory_limit: 8 * 1024 * 1024)
{:ok, rt} = QuickBEAM.start(opts)
```

Or use `QuickBEAM.new/1` as a concise runtime constructor:

```elixir
{:ok, rt} = QuickBEAM.new(sandbox: :strict)
{:ok, browser_rt} = QuickBEAM.new(sandbox: :browser)
{:ok, node_rt} = QuickBEAM.new(sandbox: :node)
```

Presets are plain keyword options. You can override any value.

## Compile-time JavaScript sigil

Import `QuickBEAM` to use `~JS`:

```elixir
import QuickBEAM

source = ~JS"1 + 2"
chunk = ~JS"1 + 2"c
```

The sigil accepts only string literals and validates JavaScript while Elixir code
is compiled. The `c` modifier returns a source-only `%QuickBEAM.Chunk{}`.

## Chunks

Chunks are first-class scripts:

```elixir
{:ok, chunk} = QuickBEAM.parse_chunk("1 + 2")
{:ok, compiled} = QuickBEAM.compile_chunk(rt, "1 + 2")
{:ok, 3} = QuickBEAM.eval(rt, compiled)
```

Bang helpers are available when exceptions are preferable:

```elixir
chunk = QuickBEAM.parse_chunk!("1 + 2")
compiled = QuickBEAM.compile_chunk!(rt, "1 + 2")
3 = QuickBEAM.eval!(rt, compiled)
```

If `eval/3` receives a compiled chunk with options such as `vars:` or `timeout:`,
it evaluates the source path so option semantics stay identical to normal eval.

## Host APIs with `QuickBEAM.API`

Define host functions with `js`:

```elixir
defmodule MyApp.Tools do
  use QuickBEAM.API, scope: "tools.math"

  js double(n), do: n * 2

  js add(a, b), runtime do
    QuickBEAM.set_global(runtime, "lastCall", "add")
    a + b
  end

  @variadic true
  js join(args), do: Enum.join(args, ":")

  def install(%QuickBEAM.API.Context{}) do
    ~JS"globalThis.toolsInstalled = true"c
  end
end

{:ok, rt} = QuickBEAM.new(sandbox: :strict)
:ok = QuickBEAM.load_api(rt, MyApp.Tools)
{:ok, 10} = QuickBEAM.eval(rt, "tools.math.double(5)")
```

`defjs` remains as a compatibility alias for `js`.

Supported host API features:

- nested scopes: `scope: "tools.math"` or `scope: [:tools, :math]`
- load-time scope override: `QuickBEAM.load_api(rt, MyAPI, scope: "custom")`
- install data: `QuickBEAM.load_api(rt, MyAPI, data: value)`
- multi-clause functions with guards
- multi-arity functions exported under one JavaScript name
- variadic functions with `@variadic true`
- runtime-aware functions via the three-argument form
- structured JS errors with `raise_js!/2`

Example structured error:

```elixir
js read(path) do
  if forbidden?(path), do: raise_js!("TypeError", "forbidden path")
  File.read!(path)
end
```

From JavaScript this throws a `TypeError`.

## Values

`QuickBEAM.Value` exposes public guards/helpers for low-level BEAM-mode values:

```elixir
import QuickBEAM.Value

is_object(value)
is_function(value)
is_symbol(value)
is_bigint(value)
QuickBEAM.Value.bigint(123)
```

Most NIF-mode calls convert to ordinary Elixir data. These helpers are intended
for BEAM-mode integrations, tests, and advanced host APIs.

## Disassembly

QuickBEAM can inspect native QuickJS bytecode and generated BEAM code:

```elixir
{:ok, rt} = QuickBEAM.start()
{:ok, bytecode} = QuickBEAM.compile(rt, "function add(a, b) { return a + b }")
{:ok, js_bc} = QuickBEAM.disasm(bytecode)

{:ok, beam_rt} = QuickBEAM.start(mode: :beam, apis: false)
{:ok, beam_disasm} = QuickBEAM.disasm(beam_rt, "function fib(n) { return n < 2 ? n : fib(n-1) + fib(n-2) }")
```

This keeps embedded JavaScript inspectable instead of opaque.
