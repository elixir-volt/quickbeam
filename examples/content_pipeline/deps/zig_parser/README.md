# Zig.Parser

Parses Zig files.

Note: This version of Zig.Parser is pinned to Zig 0.14.x

Future versions of Zig.Parser will be pinned to Zig version releases, so that
The Zig PEG spec will be kept in-line, the version it's pinned to will be 
notated here.

When Zig reaches v1.0, Zig.Parser will be able to parse multiple versions
of the language, or possibly support forks of Zig as necessary to be able
to handle other features.

## Installation

The package can be installed by adding `zig_parser` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zig_parser, "~> 0.5.1"}
  ]
end
```

Documentation can be found at <https://hexdocs.pm/zig_parser>.

