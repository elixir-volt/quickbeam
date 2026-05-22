defmodule QuickBEAM.VM.ObjectModel.FunctionPrototypeGet do
  @moduledoc "Function prototype-chain lookup helpers."

  alias QuickBEAM.VM.{Heap}
  alias QuickBEAM.VM.Execution.PrototypeState
  alias QuickBEAM.VM.ObjectModel.{Get, Prototype, PrototypeLookup, Static}
  alias QuickBEAM.VM.Runtime.Function
  alias QuickBEAM.VM.Runtime.FunctionKinds

  def constructor(%QuickBEAM.VM.Function{} = fun) do
    case FunctionKinds.constructor(fun) do
      {name, callback} -> constructor(name, callback, fun)
      nil -> fallback(:undefined, :undefined, "constructor")
    end
  end

  def constructor(_), do: fallback(:undefined, :undefined, "constructor")

  def to_string_tag(callable, key) do
    case Prototype.get(callable) do
      {:obj, _} = proto -> Get.get(proto, key)
      _ -> fallback(:undefined, callable, key)
    end
  end

  def own_or_parent(%QuickBEAM.VM.Function{} = fun, key) when key in ["length", "name"] do
    if Static.deleted?(fun, key),
      do: fallback(:undefined, fun, key),
      else: Function.proto_property(fun, key)
  end

  def own_or_parent(%QuickBEAM.VM.Function{} = fun, key) do
    case Heap.get_parent_ctor(fun) do
      nil -> fallback(:undefined, fun, key)
      parent -> fallback(Get.get(parent, key), fun, key)
    end
  end

  def closure_own_or_parent({:closure, _, %QuickBEAM.VM.Function{} = fun} = closure, key)
      when key in ["length", "name"] do
    if Static.deleted?(closure, key) or Static.deleted?(fun, key),
      do: fallback(:undefined, closure, key),
      else: Function.proto_property(closure, key)
  end

  def closure_own_or_parent(
        {:closure, _, %QuickBEAM.VM.Function{} = fun} = closure,
        key,
        call_getter
      ) do
    case Heap.get_parent_ctor(fun) do
      nil -> fallback(:undefined, closure, key)
      parent -> fallback(parent_static_property(parent, key, closure, call_getter), closure, key)
    end
  end

  def fallback(:undefined, fun, key) do
    case Heap.get_func_proto() do
      {:obj, _} = proto -> PrototypeLookup.fallback_to_object_proto(Get.own(proto, key), fun, key)
      _ -> PrototypeLookup.fallback_to_object_proto(Function.proto_property(fun, key), fun, key)
    end
  end

  def fallback(val, _fun, _key), do: val

  defp constructor(name, callback, fun) do
    ctor = {:builtin, name, callback}
    Heap.put_ctor_static(ctor, "prototype", constructor_prototype(name, ctor, fun))
    ctor
  end

  defp constructor_prototype(name, ctor, fun) do
    PrototypeState.cached({:qb_function_kind_constructor_prototype, name}, fn ->
      case Prototype.get(fun) do
        {:obj, _} = existing ->
          existing

        _ ->
          Heap.wrap(%{
            "constructor" => ctor,
            {:symbol, "Symbol.toStringTag"} => name,
            "__proto__" => Heap.get_func_proto()
          })
      end
    end)
  end

  defp parent_static_property(nil, _key, _receiver, _call_getter), do: :undefined
  defp parent_static_property(:undefined, _key, _receiver, _call_getter), do: :undefined

  defp parent_static_property(parent, key, receiver, call_getter) do
    case Map.fetch(Heap.get_ctor_statics(parent), key) do
      {:ok, {:accessor, getter, _}} when getter != nil -> call_getter.(getter, receiver)
      {:ok, {:accessor, nil, _}} -> :undefined
      {:ok, :deleted} -> :undefined
      {:ok, val} -> val
      :error -> parent_own_or_next(parent, key, receiver, call_getter)
    end
  end

  defp parent_own_or_next(parent, key, receiver, call_getter) do
    case Get.own(parent, key) do
      {:accessor, getter, _} when getter != nil -> call_getter.(getter, receiver)
      {:accessor, nil, _} -> :undefined
      :undefined -> parent_static_property(next_static_parent(parent), key, receiver, call_getter)
      val -> val
    end
  end

  defp next_static_parent({:closure, _, %QuickBEAM.VM.Function{} = fun}),
    do: Heap.get_parent_ctor(fun)

  defp next_static_parent(%QuickBEAM.VM.Function{} = fun), do: Heap.get_parent_ctor(fun)

  defp next_static_parent({:builtin, _, _} = builtin),
    do: Map.get(Heap.get_ctor_statics(builtin), "__proto__")

  defp next_static_parent(_), do: nil
end
