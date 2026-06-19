defmodule QuickBEAM.VM.Host.Web.URL.SearchParamsState do
  @moduledoc "Heap-backed URLSearchParams entry storage helpers."

  alias QuickBEAM.VM.Heap

  def new(entries) do
    ref = make_ref()
    save(ref, entries)
    ref
  end

  def from_search(search) do
    query = strip_question(search)
    if query == "", do: [], else: QuickBEAM.URL.dissect_query([query])
  end

  def sync_from_search(ref, search), do: save(ref, from_search(search))

  def entries(ref) do
    case Heap.get_obj(ref, %{}) do
      %{"entries" => list} when is_list(list) -> list
      _ -> []
    end
  end

  def append(ref, entry), do: save(ref, entries(ref) ++ [entry])

  def set(ref, name, value) do
    ref
    |> entries()
    |> Enum.reject(fn [key, _] -> key == name end)
    |> Kernel.++([[name, value]])
    |> then(&save(ref, &1))
  end

  def delete(ref, name, :undefined), do: delete_all(ref, name)
  def delete(ref, name, nil), do: delete_all(ref, name)

  def delete(ref, name, value) do
    value = to_string(value)

    ref
    |> entries()
    |> Enum.reject(fn [key, entry_value] -> key == name and entry_value == value end)
    |> then(&save(ref, &1))
  end

  def sort(ref) do
    ref
    |> entries()
    |> Enum.sort_by(fn [key, _] -> key end)
    |> then(&save(ref, &1))
  end

  def save(ref, entries), do: Heap.put_obj(ref, %{"entries" => entries})

  defp delete_all(ref, name) do
    ref
    |> entries()
    |> Enum.reject(fn [key, _] -> key == name end)
    |> then(&save(ref, &1))
  end

  defp strip_question("?" <> query), do: query
  defp strip_question(query), do: query
end
