# Protoss

![tests](https://github.com/ityonemo/protoss/actions/workflows/basic-workflow.yml/badge.svg)

Evil and Powerful Protocols for Elixir

Protocols are just modules!  And sometimes you just want to do
module things in protocols.  And when you're in control of both
the protocol and the module you're implementing for, colocating
the code in the module you're writing *just makes sense*.  This
library does this automatically for you.

## Usage

### Protocol definition

```elixir
use Protoss

defprotocol MyProtocol do
  # this works like a normal protocol forward definition.
  def fun_must_be_implemented(argument)

  # delegations forward to the passed module.  Currently
  # this is not currently runtime-checked, but it will be 
  # in the future under a flag.
  #
  # call as:
  # `MyProtocol.from_json(MyStruct, ...)`
  #
  defdelegate from_json(module, argument)

  # after block separates protocol code from module code
after

  # struct protocol implementations MUST implement these
  # extra callbacks:
  @callback extra_callback() :: term

  # this can be called directly as: `MyProtocol.root_function()`
  def root_function do
    :ok
  end
end
```

### Protocol implementation

In your (struct) protocols, the implementation of `MyProtocol` from above
would look like this.

```elixir
defmodule MyStruct do
  defstruct [:value]

  use MyProtocol

  @impl MyProtocol
  def fun_must_be_implemented(%__MODULE__{value: value}), do: value

  # note the arity change!
  @impl MyProtocol
  def from_json(%{"value" => value}), do: %__MODULE__{value: value}

  @impl MyProtocol
  def extra_callback, do: "I was required to implement this"
end
```

### Formatter changes

In order to get proper formatting, you should add the following option to your `.formatter.exs`

`locals_without_parens: [defdelegate: 1]`

## Installation

The package is available on hex and can be installed by adding `protoss` to your 
list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:protoss, "~> 0.2"}
  ]
end
```

Documentation can be found at <https://hexdocs.pm/protoss>.

