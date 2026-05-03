defmodule QuickBEAM.VM.Runtime.Collections do
  @moduledoc "Shared helpers for collection builtins."

  alias QuickBEAM.VM.{Heap, JSThrow}

  def validate_weak_key!({:obj, _}, _kind), do: :ok
  def validate_weak_key!({:symbol, _, _}, _kind), do: :ok

  def validate_weak_key!(_value, kind) do
    JSThrow.type_error!("invalid value used as #{kind} key")
  end

  def array_proto_iterator_status do
    sym_iter = {:symbol, "Symbol.iterator"}

    case Heap.get_array_proto() do
      {:obj, proto_ref} ->
        proto_data = Heap.get_obj(proto_ref, %{})

        case is_map(proto_data) && Map.get(proto_data, sym_iter) do
          nil -> :deleted
          false -> :deleted
          :deleted -> :deleted
          {:builtin, "[Symbol.iterator]", _} -> :default
          other -> other
        end

      _ ->
        :default
    end
  end
end
