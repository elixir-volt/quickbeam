defmodule QuickBEAM.VM.Execution.JSONState do
  @moduledoc "Process-local state used while JSON.stringify traverses values."

  @property_list_key {__MODULE__, :property_list}
  @seen_refs_key {__MODULE__, :seen_refs}
  @replacer_function_key {__MODULE__, :replacer_function}

  def snapshot do
    %{
      property_list: Process.get(@property_list_key),
      seen_refs: Process.get(@seen_refs_key),
      replacer_function: Process.get(@replacer_function_key)
    }
  end

  def restore(%{property_list: property_list, seen_refs: seen_refs, replacer_function: replacer}) do
    restore_value(@property_list_key, property_list)
    restore_value(@seen_refs_key, seen_refs)
    restore_value(@replacer_function_key, replacer)
    :ok
  end

  def put_replacer_function(replacer), do: Process.put(@replacer_function_key, replacer)
  def delete_replacer_function, do: Process.delete(@replacer_function_key)
  def replacer_function, do: Process.get(@replacer_function_key)

  def put_property_list(list), do: Process.put(@property_list_key, list)
  def delete_property_list, do: Process.delete(@property_list_key)
  def property_list, do: Process.get(@property_list_key)

  def reset_seen_refs, do: Process.put(@seen_refs_key, MapSet.new())
  def seen_refs, do: Process.get(@seen_refs_key, MapSet.new())
  def put_seen_refs(refs), do: Process.put(@seen_refs_key, refs)

  defp restore_value(key, nil), do: Process.delete(key)
  defp restore_value(key, value), do: Process.put(key, value)
end
