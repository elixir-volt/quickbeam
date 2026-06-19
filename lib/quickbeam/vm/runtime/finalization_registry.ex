defmodule QuickBEAM.VM.Runtime.FinalizationRegistry do
  @moduledoc "Minimal JS `FinalizationRegistry` builtin for Test262 observable semantics."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.{Builtin, Heap, JSThrow, Runtime}
  alias QuickBEAM.VM.Runtime.Collections

  @cleanup "__finalization_registry_cleanup__"
  @cells "__finalization_registry_cells__"

  defintrinsic "FinalizationRegistry", intrinsic_key: :finalization_registry do
    constructor(constructor(), length: 1, phase: :weak_refs)

    prototype extends: :object do
      @ecma "26.2.3.2"
      method "register", length: 2 do
        register(args, this)
      end

      @ecma "26.2.3.3"
      method "unregister", length: 1 do
        unregister(args, this)
      end

      to_string_tag("FinalizationRegistry")
    end
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, this ->
      cleanup = arg(args, 0, :undefined)

      unless Builtin.callable?(cleanup) do
        JSThrow.type_error!("FinalizationRegistry cleanup callback must be callable")
      end

      {ref, instance_proto} =
        case this do
          {:obj, this_ref} ->
            existing = Heap.get_obj(this_ref, %{})

            {this_ref,
             Map.get(existing, proto(), Runtime.global_class_proto("FinalizationRegistry"))}

          _ ->
            {make_ref(), Runtime.global_class_proto("FinalizationRegistry")}
        end

      Heap.put_obj(ref, %{@cleanup => cleanup, @cells => [], proto() => instance_proto})
      {:obj, ref}
    end
  end

  defp register(args, this) do
    ref = require_registry!(this)
    target = arg(args, 0, :undefined)
    held_value = arg(args, 1, :undefined)
    token = arg(args, 2, :undefined)

    Collections.validate_weak_key!(target, "FinalizationRegistry target")

    if held_value == target do
      JSThrow.type_error!("FinalizationRegistry holdings must not be the target")
    end

    unless token == :undefined do
      Collections.validate_weak_key!(token, "FinalizationRegistry unregister token")
    end

    object = Heap.get_obj(ref, %{})
    cells = Map.get(object, @cells, [])

    Heap.put_obj_key(ref, @cells, [
      %{target: target, held_value: held_value, token: token} | cells
    ])

    :undefined
  end

  defp unregister(args, this) do
    ref = require_registry!(this)
    token = arg(args, 0, :undefined)
    Collections.validate_weak_key!(token, "FinalizationRegistry unregister token")

    object = Heap.get_obj(ref, %{})
    cells = Map.get(object, @cells, [])
    remaining = Enum.reject(cells, &(&1.token == token))
    Heap.put_obj_key(ref, @cells, remaining)
    length(remaining) != length(cells)
  end

  defp require_registry!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, @cells) -> ref
      _ -> JSThrow.type_error!("Method requires a FinalizationRegistry")
    end
  end

  defp require_registry!(_), do: JSThrow.type_error!("Method requires a FinalizationRegistry")
end
