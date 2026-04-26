defmodule QuickBEAM.VM.Runtime.Web.Fetch.JSON do
  @moduledoc "JSON conversion helpers for Fetch body methods."

  alias QuickBEAM.VM.{Heap, JSThrow}

  def parse(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, val} -> from_elixir(val)
      _ -> JSThrow.syntax_error!("Unexpected token in JSON")
    end
  end

  def encode(val), do: Jason.encode!(to_elixir(val))

  defp from_elixir(val) when is_map(val) do
    Heap.wrap(Map.new(val, fn {key, value} -> {key, from_elixir(value)} end))
  end

  defp from_elixir(val) when is_list(val), do: Heap.wrap(Enum.map(val, &from_elixir/1))
  defp from_elixir(val), do: val

  defp to_elixir({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) ->
        map
        |> Enum.reject(fn {key, _value} ->
          not is_binary(key) or String.starts_with?(key, "__")
        end)
        |> Map.new(fn {key, value} -> {key, to_elixir(value)} end)

      list when is_list(list) ->
        Enum.map(list, &to_elixir/1)

      _ ->
        nil
    end
  end

  defp to_elixir(value) when is_binary(value), do: value
  defp to_elixir(value) when is_number(value), do: value
  defp to_elixir(true), do: true
  defp to_elixir(false), do: false
  defp to_elixir(nil), do: nil
  defp to_elixir(:undefined), do: nil
  defp to_elixir(:nan), do: nil
  defp to_elixir(:infinity), do: nil
  defp to_elixir({:bigint, value}), do: value
  defp to_elixir(_), do: nil
end
