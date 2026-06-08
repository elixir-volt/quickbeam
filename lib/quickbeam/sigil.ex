defmodule QuickBEAM.Sigil do
  @moduledoc false

  def expand(code, opts) do
    code =
      case code do
        {:<<>>, _, [literal]} when is_binary(literal) -> literal
        _ -> raise "~JS only accepts string literals, received:\n\n#{Macro.to_string(code)}"
      end

    case QuickBEAM.Chunk.validate(code) do
      {:ok, _chunk} -> :ok
      {:error, error} -> raise error
    end

    case opts do
      [?c] ->
        Macro.escape(QuickBEAM.Chunk.new!(code))

      [] ->
        code

      other ->
        raise ArgumentError, "unsupported ~JS modifier(s): #{inspect(List.to_string(other))}"
    end
  end
end
