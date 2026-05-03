defmodule QuickBEAM.VM.ObjectModel.Static do
  @moduledoc "Shared helpers for function/static object property semantics."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

  def delete_static(fun, key) do
    key_str = if is_binary(key), do: key, else: Values.stringify(key)
    statics = Heap.get_ctor_statics(fun)

    if Map.has_key?(statics, key_str) do
      Heap.put_ctor_statics(fun, Map.delete(statics, key_str))
      true
    else
      delete_missing_static(fun, key_str, statics)
    end
  end

  def with_has_property?({:obj, _} = obj, key) do
    if Put.has_property(obj, key) do
      unscopables = Get.get(obj, {:symbol, "Symbol.unscopables"})

      case unscopables do
        {:obj, _} -> not Values.truthy?(Get.get(unscopables, key))
        _ -> true
      end
    else
      false
    end
  end

  def with_has_property?(_, _), do: false

  defp delete_missing_static({:builtin, _, _} = fun, key_str, statics) do
    case Get.get(fun, key_str) do
      :undefined ->
        true

      val when is_number(val) or val in [:infinity, :neg_infinity, :nan] ->
        false

      _ ->
        Heap.put_ctor_statics(fun, Map.put(statics, key_str, :deleted))
        true
    end
  end

  defp delete_missing_static(_fun, _key_str, _statics), do: true
end
