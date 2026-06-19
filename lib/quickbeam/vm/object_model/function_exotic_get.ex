defmodule QuickBEAM.VM.ObjectModel.FunctionExoticGet do
  @moduledoc "Function exotic own-property lookup helpers."

  alias QuickBEAM.VM.{Heap, JSThrow, Value}
  alias QuickBEAM.VM.Runtime.Function

  @restricted_properties ["caller", "arguments"]
  @builtin_properties ["length", "name", "caller", "arguments"]

  def own_property(%QuickBEAM.VM.Function{func_kind: 2}, "prototype", _call_getter),
    do: :undefined

  def own_property(%QuickBEAM.VM.Function{} = fun, "prototype", call_getter) do
    constructor_static_property(fun, "prototype", call_getter, fn ->
      Heap.get_or_create_prototype(fun)
    end)
  end

  def own_property(%QuickBEAM.VM.Function{func_kind: kind}, key, _call_getter)
      when kind in [1, 2, 3] and key in @restricted_properties do
    restricted_property_error!()
  end

  def own_property(%QuickBEAM.VM.Function{is_strict_mode: true}, key, _call_getter)
      when key in @restricted_properties do
    restricted_property_error!()
  end

  def own_property(%QuickBEAM.VM.Function{} = fun, key, _call_getter) do
    case Map.get(Heap.get_ctor_statics(fun), key, :not_found) do
      :not_found when key in @builtin_properties -> Function.proto_property(fun, key)
      :not_found -> :undefined
      :deleted -> :undefined
      val -> val
    end
  end

  def own_property(
        {:closure, _, %QuickBEAM.VM.Function{func_kind: 2}},
        "prototype",
        _call_getter
      ),
      do: :undefined

  def own_property({:closure, _, %QuickBEAM.VM.Function{}} = closure, "prototype", call_getter) do
    constructor_static_property(closure, "prototype", call_getter, fn ->
      Heap.get_or_create_prototype(closure)
    end)
  end

  def own_property({:closure, _, %QuickBEAM.VM.Function{func_kind: kind}}, key, _call_getter)
      when kind in [1, 2, 3] and key in @restricted_properties do
    restricted_property_error!()
  end

  def own_property({:closure, _, %QuickBEAM.VM.Function{is_strict_mode: true}}, key, _call_getter)
      when key in @restricted_properties do
    restricted_property_error!()
  end

  def own_property({:closure, _, %QuickBEAM.VM.Function{} = fun} = closure, key, call_getter) do
    case Map.get(Heap.get_ctor_statics(closure), key, :not_found) do
      :not_found -> inherited_closure_static(closure, fun, key)
      :deleted -> :undefined
      {:accessor, getter, _} when getter != nil -> call_getter.(getter, closure)
      val -> val
    end
  end

  def own_property({:bound, _, _, _, _} = bound, key, call_getter) do
    case Map.get(Heap.get_ctor_statics(bound), key, :undefined) do
      :undefined -> Function.proto_property(bound, key)
      {:accessor, getter, _} when getter != nil -> call_getter.(getter, bound)
      {:accessor, nil, _} -> :undefined
      val -> val
    end
  end

  defp constructor_static_property(fun, key, call_getter, create_prototype) do
    case Map.get(Heap.get_ctor_statics(fun), key, :not_set) do
      :not_set -> if Value.has_function_prototype?(fun), do: create_prototype.(), else: :undefined
      {:accessor, getter, _} when getter != nil -> call_getter.(getter, fun)
      val -> val
    end
  end

  defp inherited_closure_static(closure, fun, key) do
    case Map.get(Heap.get_ctor_statics(fun), key, :not_found) do
      :not_found when key in @builtin_properties -> Function.proto_property(closure, key)
      :not_found -> :undefined
      :deleted -> :undefined
      val -> val
    end
  end

  defp restricted_property_error! do
    JSThrow.type_error!(
      "'caller' and 'arguments' are restricted function properties and cannot be accessed in this context."
    )
  end
end
