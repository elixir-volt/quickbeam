defmodule QuickBEAM.VM.Host.Web.FormData.State do
  @moduledoc "Heap-backed FormData entry storage helpers."

  alias QuickBEAM.VM.Heap

  def new do
    ref = make_ref()
    save(ref, [])
    ref
  end

  def entries(ref) do
    case Heap.get_obj(ref, %{}) do
      %{list: list} when is_list(list) -> list
      _ -> []
    end
  end

  def append(ref, entry), do: save(ref, entries(ref) ++ [entry])

  def replace(ref, name, entry) do
    entries = Enum.reject(entries(ref), fn {key, _value} -> key == name end)
    save(ref, entries ++ [entry])
  end

  def delete(ref, name) do
    ref
    |> entries()
    |> Enum.reject(fn {key, _value} -> key == name end)
    |> then(&save(ref, &1))
  end

  def save(ref, entries), do: Heap.put_obj(ref, %{list: entries})
end
