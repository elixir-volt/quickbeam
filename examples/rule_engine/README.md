# Rule Engine

User-defined business rules evaluated safely in isolated JS runtimes.

This is the canonical use case for embedding JS in an Elixir app: letting users
write custom logic (pricing formulas, validation rules, data transformations)
that runs inside your application with strict sandboxing.

## Architecture

Each rule is a JS source string that gets its own QuickBEAM runtime:

- **`apis: false`** — no `fetch`, no `setTimeout`, no filesystem, no DOM
- **Memory limits** — OOM returns `{:error, %QuickBEAM.JSError{}}`
- **Timeouts** — infinite loops get interrupted
- **Handlers** — rules can only access what you explicitly expose via `Beam.call()`
- **Isolation** — rules can't see each other's globals

Rules are managed dynamically via DynamicSupervisor + Registry: load, unload,
reload, and call them at runtime.

## Usage

```elixir
{:ok, _} = RuleEngine.start_link()

# Load a rule with a handler
RuleEngine.load(:pricing, """
  async function calculate(sku, qty) {
    const product = await Beam.call("lookup", sku)
    return product.price * qty
  }
""", handlers: %{
  "lookup" => fn [sku] -> Products.get(sku) end
})

# Call it
{:ok, total} = RuleEngine.call(:pricing, "calculate", ["SKU-001", 3])

# Hot-reload with new logic
RuleEngine.reload(:pricing, new_source)

# Clean up
RuleEngine.unload(:pricing)
```

## Running

```bash
mix deps.get
mix run run.exs
```

## Tests

```bash
mix test
```
