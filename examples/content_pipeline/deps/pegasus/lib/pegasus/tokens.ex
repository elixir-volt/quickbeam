defmodule Pegasus.Tokens do
  @moduledoc false

  # Collects together parsers for all of the minor tokens for Peg parsers
  #
  # ```peg
  # LEFTARROW       <- '<-' Spacing
  # SLASH           <- '/' Spacing
  # AND             <- '&' Spacing
  # NOT             <- '!' Spacing
  # QUERY           <- '?' Spacing
  # STAR            <- '*' Spacing
  # PLUS            <- '+' Spacing
  # OPEN            <- '(' Spacing
  # CLOSE           <- ')' Spacing
  # DOT             <- '.' Spacing
  # BEGIN           <- '<' Spacing
  # END             <- '>' Spacing
  # ```

  import NimbleParsec
  alias Pegasus.Components

  @definitions %{
    leftarrow: "<-",
    slash: "/",
    and: "&",
    not: "!",
    query: "?",
    star: "*",
    plus: "+",
    open: "(",
    close: ")",
    dot: ".",
    begin: "<",
    ender: ">"
  }

  for {name, token} <- @definitions do
    def unquote(name)(previous \\ empty()) do
      previous
      |> ignore(string(unquote(token)))
      |> post_traverse({__MODULE__, :tokenize, [unquote(name)]})
      |> Components.spacing()
    end
  end

  def tokenize(rest, args, context, _, _, token) do
    {rest, [token | args], context}
  end
end
