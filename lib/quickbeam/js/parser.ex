defmodule QuickBEAM.JS.Parser do
  @moduledoc "Experimental hand-written JavaScript parser for QuickBEAM."

  alias QuickBEAM.JS.Parser.Lexer

  defstruct tokens: {},
            index: 0,
            token_count: 0,
            last_token: nil,
            errors: [],
            source_type: :script,
            yield_allowed?: false,
            await_allowed?: false

  @type t :: %__MODULE__{}

  @assignment_ops ~w[= += -= *= /= %= **= <<= >>= >>>= &= ^= |= &&= ||= ??=]
  @logical_ops ~w[|| && ??]
  @update_ops ~w[++ --]

  @precedence %{
    "," => {1, :left},
    "=" => {2, :right},
    "+=" => {2, :right},
    "-=" => {2, :right},
    "*=" => {2, :right},
    "/=" => {2, :right},
    "%=" => {2, :right},
    "**=" => {2, :right},
    "<<=" => {2, :right},
    ">>=" => {2, :right},
    ">>>=" => {2, :right},
    "&=" => {2, :right},
    "^=" => {2, :right},
    "|=" => {2, :right},
    "&&=" => {2, :right},
    "||=" => {2, :right},
    "??=" => {2, :right},
    "?" => {3, :right},
    "??" => {4, :left},
    "||" => {5, :left},
    "&&" => {6, :left},
    "|" => {7, :left},
    "^" => {8, :left},
    "&" => {9, :left},
    "==" => {10, :left},
    "!=" => {10, :left},
    "===" => {10, :left},
    "!==" => {10, :left},
    "<" => {11, :left},
    ">" => {11, :left},
    "<=" => {11, :left},
    ">=" => {11, :left},
    "in" => {11, :left},
    "instanceof" => {11, :left},
    "<<" => {12, :left},
    ">>" => {12, :left},
    ">>>" => {12, :left},
    "+" => {13, :left},
    "-" => {13, :left},
    "*" => {14, :left},
    "/" => {14, :left},
    "%" => {14, :left},
    "**" => {15, :right}
  }

  @doc "Parses JavaScript source into the experimental QuickBEAM JS AST."
  def parse(source, opts \\ []) when is_binary(source) do
    source_type = Keyword.get(opts, :source_type, :script)

    with {:ok, tokens} <- Lexer.tokenize(source) do
      state = new_state(tokens, source_type: source_type)
      {program, state} = parse_program(state)

      case state.errors do
        [] -> {:ok, program}
        errors -> {:error, program, Enum.reverse(errors)}
      end
    else
      {:error, tokens, errors} ->
        state = new_state(tokens, source_type: source_type, errors: errors)
        {program, state} = parse_program(state)
        {:error, program, Enum.reverse(state.errors)}
    end
  end

  @doc "Parses JavaScript source and raises when syntax errors are produced."
  def parse!(source, opts \\ []) do
    case parse(source, opts) do
      {:ok, ast} -> ast
      {:error, _ast, [error | _]} -> raise SyntaxError, message: error.message
      {:error, _ast, []} -> raise SyntaxError, message: "failed to parse JavaScript"
    end
  end

  use QuickBEAM.JS.Parser.State
  use QuickBEAM.JS.Parser.Statements
  use QuickBEAM.JS.Parser.Modules
  use QuickBEAM.JS.Parser.Patterns
  use QuickBEAM.JS.Parser.ValidationDelegates
  use QuickBEAM.JS.Parser.Classes
  use QuickBEAM.JS.Parser.Expressions
end
