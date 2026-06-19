defmodule QuickBEAM.VM.ObjectModel.IndexedExoticGet do
  @moduledoc "Indexed own-property lookup for VM array-like and string values."

  alias QuickBEAM.VM.ObjectModel.PropertyKey
  alias QuickBEAM.VM.Runtime.String, as: JSString

  def own_property({:qb_arr, arr}, "length"), do: :array.size(arr)

  def own_property({:qb_arr, arr}, key) when is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> if idx < :array.size(arr), do: :array.get(idx, arr), else: :undefined
      :error -> :undefined
    end
  end

  def own_property(list, "length") when is_list(list), do: length(list)

  def own_property(list, key) when is_list(list) and is_binary(key) do
    case PropertyKey.array_index(key) do
      {:ok, idx} -> Enum.at(list, idx, :undefined)
      :error -> :undefined
    end
  end

  def own_property(string, "length") when is_binary(string), do: string_length(string)

  def own_property(string, key) when is_binary(string) do
    case PropertyKey.array_index(key) do
      {:ok, index} when index < 4_294_967_295 -> JSString.utf16_code_unit_at(string, index)
      _ -> JSString.proto_property(key)
    end
  end

  def own_property(_value, _key), do: :undefined

  defp string_length(string), do: JSString.utf16_length(string)
end
