defmodule QuickBEAM.VM.Runtime.ArrayIterator do
  @moduledoc "Runtime support for Array, String, and TypedArray iterator objects."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [typed_array: 0]

  alias QuickBEAM.VM.{Heap, JSThrow, Runtime}
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Runtime.{ArraySource, IteratorResult}

  def new(target, mode) do
    state_ref = make_ref()
    iterator_ref = make_ref()

    Heap.put_obj(state_ref, %{
      "target" => iterator_target(target),
      "mode" => mode,
      "index" => 0,
      "done" => false
    })

    Heap.put_obj(
      iterator_ref,
      object heap: false, extends: prototype() do
        prop("__array_iterator_state__", {:obj, state_ref})
      end
    )

    {:obj, iterator_ref}
  end

  defp prototype do
    array_ctor = Runtime.global_constructor("Array")
    statics = Heap.get_ctor_statics(array_ctor)

    case Map.get(statics, :__array_iterator_prototype__) do
      {:obj, _} = proto ->
        proto

      _ ->
        proto = build_prototype()
        Heap.put_ctor_static(array_ctor, :__array_iterator_prototype__, proto)
        proto
    end
  end

  defp build_prototype do
    object extends: Runtime.global_class_proto("Iterator") do
      method "next" do
        next(this)
      end

      symbol :iterator do
        method do
          this
        end
      end

      symbol :toStringTag do
        data("Array Iterator", writable: false, enumerable: false, configurable: true)
      end
    end
  end

  defp next({:obj, ref}) do
    case Heap.get_obj(ref, %{}) do
      %{"__array_iterator_state__" => {:obj, state_ref}} ->
        next_state(state_ref)

      _ ->
        incompatible_receiver!()
    end
  end

  defp next(_), do: incompatible_receiver!()

  defp next_state(state_ref) do
    state = Heap.get_obj(state_ref, %{})
    index = Map.get(state, "index", 0)

    if Map.get(state, "done") == true do
      IteratorResult.done()
    else
      next_value(state_ref, state, index)
    end
  end

  defp next_value(state_ref, state, index) do
    target = Map.fetch!(state, "target")

    if index >= iterator_length(target) do
      Heap.put_obj(state_ref, Map.put(state, "done", true))
      IteratorResult.done()
    else
      Heap.put_obj(state_ref, Map.put(state, "index", index + 1))
      IteratorResult.new(iterator_value(state, target, index), false)
    end
  end

  defp iterator_value(state, target, index) do
    case Map.get(state, "mode") do
      :values -> target_value(target, index)
      :keys -> index
      :entries -> Heap.wrap([index, target_value(target, index)])
    end
  end

  defp iterator_target(list) when is_list(list), do: {:tuple, List.to_tuple(list)}

  defp iterator_target(string) when is_binary(string),
    do: {:tuple, string |> String.codepoints() |> List.to_tuple()}

  defp iterator_target(target), do: target

  defp iterator_length({:obj, ref} = obj) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} ->
        if Runtime.TypedArray.out_of_bounds?(obj) do
          JSThrow.type_error!("TypedArray is out of bounds")
        end

        Runtime.TypedArray.element_count(obj)

      _ ->
        ArraySource.length(obj)
    end
  end

  defp iterator_length(target), do: ArraySource.length(target)

  defp target_value({:obj, ref} = obj, index) do
    case Heap.get_obj(ref, %{}) do
      %{typed_array() => true} -> Get.get(obj, Integer.to_string(index))
      _ -> ArraySource.get(obj, index)
    end
  end

  defp target_value(target, index), do: ArraySource.get(target, index)

  defp incompatible_receiver!,
    do: JSThrow.type_error!("Array Iterator next called on incompatible receiver")
end
