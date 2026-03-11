# Content moderation pipeline

Three JS runtimes as supervised BEAM processes, communicating via message passing.

```
post → [sanitizer] → [classifier] → [enricher] → result
          strip HTML     spam detection    word count
```

Each stage is isolated. Kill any one — the supervisor restarts it, the others keep running.

## Run

```sh
elixir pipeline.exs
```

```
1 | Hello World (6 words)
2 [SPAM] | Buy Now! Free Money!!! (7 words)
3 | QuickBEAM Release (5 words)
```

## Test

```sh
mix deps.get
mix test
```

## How it works

Each `.js` file receives messages via `Beam.onMessage` and forwards to the next stage via `Beam.callSync("forward", "next_stage", data)`. The Elixir supervisor wires them together:

```elixir
children = [
  {QuickBEAM, name: :sanitizer,  script: "sanitizer.js",  handlers: %{"forward" => forward}},
  {QuickBEAM, name: :classifier, script: "classifier.js", handlers: %{"forward" => forward}},
  {QuickBEAM, name: :enricher,   script: "enricher.js",   handlers: %{"done" => collect}},
]
Supervisor.start_link(children, strategy: :one_for_one)
```

JS runtimes don't know about each other. They send messages to named atoms via a shared `forward` handler — the BEAM routes them.
