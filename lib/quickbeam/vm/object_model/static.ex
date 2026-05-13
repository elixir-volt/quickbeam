defmodule QuickBEAM.VM.ObjectModel.Static do
  @moduledoc "Shared helpers for function/static object property semantics."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Get, HasProperty}

  def delete_static(fun, key) do
    prop_key =
      if is_binary(key) or match?({:symbol, _}, key), do: key, else: Values.stringify(key)

    statics = Heap.get_ctor_statics(fun)

    cond do
      match?(
        %{configurable: false},
        Heap.get_prop_desc(fun, prop_key) || Heap.get_ctor_prop_desc(fun, prop_key)
      ) ->
        false

      Map.has_key?(statics, prop_key) and
          (match?({:builtin, _, _}, fun) or prop_key in ["name", "length"]) ->
        Heap.put_ctor_statics(fun, Map.put(statics, prop_key, :deleted))
        true

      Map.has_key?(statics, prop_key) ->
        Heap.put_ctor_statics(fun, Map.delete(statics, prop_key))
        true

      true ->
        delete_missing_static(fun, prop_key, statics)
    end
  end

  def with_has_property?({:obj, _} = obj, key) do
    if HasProperty.has_property?(obj, key) do
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

  defp delete_missing_static({:builtin, _, _} = fun, key_str, statics)
       when key_str in ["name", "length"] do
    Heap.put_ctor_statics(fun, Map.put(statics, key_str, :deleted))
    true
  end

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

  defp delete_missing_static(fun, key_str, statics)
       when key_str in ["name", "length"] and (is_tuple(fun) or is_struct(fun)) do
    Heap.put_ctor_statics(fun, Map.put(statics, key_str, :deleted))
    true
  end

  defp delete_missing_static(_fun, _key_str, _statics), do: true
end
