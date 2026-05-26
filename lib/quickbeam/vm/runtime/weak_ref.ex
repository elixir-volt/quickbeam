defmodule QuickBEAM.VM.Runtime.WeakRef do
  @moduledoc "JS `WeakRef` built-in: constructor and `deref` prototype method."

  import QuickBEAM.VM.Heap.Keys
  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.Runtime.Collections

  @target "__weak_ref_target__"

  defintrinsic "WeakRef", intrinsic_key: :weak_ref do
    constructor(constructor(), length: 1, phase: :weak_refs)

    prototype extends: :object do
      method "deref" do
        deref(args, this)
      end

      to_string_tag("WeakRef")
    end
  end

  @doc "Builds the JavaScript constructor object for this runtime builtin."
  def constructor do
    fn args, this ->
      target = arg(args, 0, :undefined)
      Collections.validate_weak_key!(target, "WeakRef")

      {ref, instance_proto} =
        case this do
          {:obj, this_ref} ->
            existing = Heap.get_obj(this_ref, %{})
            {this_ref, Map.get(existing, proto(), Runtime.global_class_proto("WeakRef"))}

          _ ->
            {make_ref(), Runtime.global_class_proto("WeakRef")}
        end

      Heap.put_obj(ref, %{@target => target, proto() => instance_proto})
      {:obj, ref}
    end
  end

  defp deref(_args, this) do
    this
    |> require_weak_ref!()
    |> Heap.get_obj(%{})
    |> Map.get(@target, :undefined)
  end

  defp require_weak_ref!({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      map when is_map(map) and is_map_key(map, @target) -> ref
      _ -> JSThrow.type_error!("Method requires a WeakRef")
    end
  end

  defp require_weak_ref!(_), do: JSThrow.type_error!("Method requires a WeakRef")
end
