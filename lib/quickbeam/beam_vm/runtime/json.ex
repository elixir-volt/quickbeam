defmodule QuickBEAM.BeamVM.Runtime.JSON do
  @moduledoc "JSON.parse and JSON.stringify."

  def object do
    {:builtin, "JSON", %{
      "parse" => {:builtin, "parse", fn [s | _] -> parse(s) end},
      "stringify" => {:builtin, "stringify", fn args -> stringify(args) end},
    }}
  end

  defp parse(s) when is_binary(s) do
    try do
      to_js(:json.decode(s))
    rescue
      ArgumentError -> throw({:js_throw, "SyntaxError: JSON.parse"})
    end
  end
  defp parse(_), do: throw({:js_throw, "SyntaxError: JSON.parse"})

  defp to_js(nil), do: nil
  defp to_js(val) when is_map(val) do
    ref = make_ref()
    map = Map.new(val, fn {k, v} -> {k, to_js(v)} end)
    Process.put({:qb_obj, ref}, map)
    {:obj, ref}
  end
  defp to_js(val) when is_list(val), do: Enum.map(val, &to_js/1)
  defp to_js(val), do: val

  defp stringify([val | _]) do
    try do
      :json.encode(to_json(val)) |> IO.iodata_to_binary()
    rescue
      ArgumentError -> :undefined
    end
  end

  defp to_json({:obj, ref}) do
    case Process.get({:qb_obj, ref}) do
      nil -> %{}
      map -> Map.new(map, fn {k, v} -> {to_string(k), to_json(v)} end)
    end
  end
  defp to_json(:undefined), do: nil
  defp to_json(:nan), do: nil
  defp to_json(:infinity), do: nil
  defp to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  defp to_json(val), do: val
end
