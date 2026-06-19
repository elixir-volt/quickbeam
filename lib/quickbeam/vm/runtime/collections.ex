defmodule QuickBEAM.VM.Runtime.Collections do
  @moduledoc "Shared helpers for collection builtins."

  import QuickBEAM.VM.Heap.Keys, only: [map_data: 0, set_data: 0]

  alias QuickBEAM.VM.{Heap, JSThrow}
  alias QuickBEAM.VM.Runtime.Map, as: JSMap
  alias QuickBEAM.VM.Runtime.Set, as: JSSet

  def validate_weak_key!({:obj, _}, _kind), do: :ok
  def validate_weak_key!(%QuickBEAM.VM.Function{}, _kind), do: :ok
  def validate_weak_key!({:closure, _, %QuickBEAM.VM.Function{}}, _kind), do: :ok
  def validate_weak_key!({:builtin, _, _}, _kind), do: :ok
  def validate_weak_key!({:bound, _, _, _, _}, _kind), do: :ok
  def validate_weak_key!({:symbol, "Symbol." <> _}, _kind), do: :ok
  def validate_weak_key!({:symbol, _, _}, _kind), do: :ok

  def validate_weak_key!(_value, kind) do
    JSThrow.type_error!("invalid value used as #{kind} key")
  end

  def proto_property(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, map_data()) and Map.has_key?(map, :weak) -> JSMap.weak_proto_property(key)
      Map.has_key?(map, map_data()) -> JSMap.proto_property(key)
      Map.has_key?(map, set_data()) and Map.has_key?(map, :weak) -> JSSet.weak_proto_property(key)
      Map.has_key?(map, set_data()) -> JSSet.proto_property(key)
      true -> :not_collection
    end
  end

  def proto_property(_, _), do: :not_collection

  def array_proto_iterator_status do
    sym_iter = {:symbol, "Symbol.iterator"}

    case Heap.get_array_proto() do
      {:obj, proto_ref} ->
        proto_data = Heap.get_obj(proto_ref, %{})

        case is_map(proto_data) && Map.get(proto_data, sym_iter) do
          nil -> :deleted
          false -> :deleted
          :deleted -> :deleted
          {:builtin, name, _} when name in ["[Symbol.iterator]", "values"] -> :default
          other -> other
        end

      _ ->
        :default
    end
  end
end
