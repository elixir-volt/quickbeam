defmodule QuickBEAM.Chunk do
  @moduledoc """
  A validated JavaScript chunk.

  Chunks are produced by `QuickBEAM.parse_chunk/2`, `QuickBEAM.compile_chunk/3`,
  or the `~JS` sigil with the `c` modifier. They keep source text plus optional
  native bytecode so callers can pass a first-class script value to
  `QuickBEAM.eval/3`.
  """

  alias QuickBEAM.JS.Error, as: JSError

  @type t :: %__MODULE__{
          source: String.t(),
          bytecode: binary() | nil,
          filename: String.t(),
          ast: term(),
          metadata: map()
        }

  @enforce_keys [:source]
  defstruct [:source, :bytecode, :ast, filename: "", metadata: %{}]

  @doc "Validates JavaScript source and returns a source-only chunk."
  @spec validate(String.t(), keyword()) :: {:ok, t()} | {:error, JSError.t()}
  def validate(source, opts \\ []) when is_binary(source) do
    filename = Keyword.get(opts, :filename, "")

    case QuickBEAM.JS.Parser.parse(source) do
      {:ok, ast} ->
        {:ok, %__MODULE__{source: source, filename: filename, ast: ast}}

      {:error, _ast, [error | _]} ->
        {:error, %JSError{name: "SyntaxError", message: error.message}}

      _ ->
        {:error, %JSError{name: "SyntaxError", message: "failed to parse JavaScript"}}
    end
  end

  @doc "Builds a source-only chunk or raises on syntax errors."
  @spec new!(String.t(), keyword()) :: t()
  def new!(source, opts \\ []) do
    case validate(source, opts) do
      {:ok, chunk} -> chunk
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec with_bytecode(t(), binary()) :: t()
  def with_bytecode(%__MODULE__{} = chunk, bytecode) when is_binary(bytecode) do
    %{chunk | bytecode: bytecode}
  end
end
