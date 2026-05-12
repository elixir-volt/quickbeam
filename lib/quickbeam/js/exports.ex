defmodule QuickBEAM.JS.Exports do
  @moduledoc false

  @type export_map :: String.t() | [export_map()] | %{String.t() => export_map()} | nil

  @spec parse(map()) :: %{String.t() => String.t() | map()} | nil
  def parse(%{"exports" => exports}) when is_binary(exports), do: %{"." => exports}

  def parse(%{"exports" => exports}) when is_map(exports) do
    if subpath_exports?(exports), do: exports, else: %{"." => exports}
  end

  def parse(_), do: nil

  @spec resolve(map(), String.t(), [String.t()]) :: {:ok, String.t()} | :error
  def resolve(export_map, subpath, conditions \\ ["default"]) do
    export_map
    |> candidates(subpath, conditions)
    |> Enum.find_value(:error, &{:ok, &1})
  end

  defp subpath_exports?(map) do
    Enum.any?(Map.keys(map), &String.starts_with?(&1, "."))
  end

  defp candidates(export_map, subpath, conditions) when is_map(export_map) do
    exact = export_map |> Map.get(subpath) |> target_candidates(conditions)

    wildcard =
      Enum.flat_map(export_map, fn {pattern, target} ->
        case wildcard_replacement(pattern, subpath) do
          nil -> []
          replacement -> replace_wildcards(target_candidates(target, conditions), replacement)
        end
      end)

    exact ++ wildcard
  end

  defp candidates(_, _, _), do: []

  defp target_candidates(nil, _conditions), do: []
  defp target_candidates(path, _conditions) when is_binary(path), do: [path]

  defp target_candidates(list, conditions) when is_list(list) do
    Enum.flat_map(list, &target_candidates(&1, conditions))
  end

  defp target_candidates(target, conditions) when is_map(target) do
    Enum.flat_map(conditions, fn condition ->
      target |> Map.get(condition) |> target_candidates(conditions)
    end)
  end

  defp target_candidates(_, _), do: []

  defp replace_wildcards(paths, replacement) do
    Enum.map(paths, &String.replace(&1, "*", replacement))
  end

  defp wildcard_replacement(pattern, subpath) do
    case String.split(pattern, "*", parts: 2) do
      [prefix, suffix] ->
        if String.starts_with?(subpath, prefix) and String.ends_with?(subpath, suffix) do
          subpath
          |> String.trim_leading(prefix)
          |> trim_suffix(suffix)
        end

      _ ->
        nil
    end
  end

  defp trim_suffix(value, ""), do: value
  defp trim_suffix(value, suffix), do: String.trim_trailing(value, suffix)
end
