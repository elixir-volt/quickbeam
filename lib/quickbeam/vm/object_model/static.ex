defmodule QuickBEAM.VM.ObjectModel.Static do
  @moduledoc "Shared helpers for function/static object property semantics."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Values
  alias QuickBEAM.VM.ObjectModel.{Get, Put}

  def delete_static(fun, key) do
    key_str = if is_binary(key), do: key, else: Values.stringify(key)
    statics = Heap.get_ctor_statics(fun)

    cond do
      match?(
        %{configurable: false},
        Heap.get_prop_desc(fun, key_str) || Heap.get_ctor_prop_desc(fun, key_str)
      ) ->
        false

      Map.has_key?(statics, key_str) and match?({:builtin, _, _}, fun) ->
        Heap.put_ctor_statics(fun, Map.put(statics, key_str, :deleted))
        true

      Map.has_key?(statics, key_str) ->
        Heap.put_ctor_statics(fun, Map.delete(statics, key_str))
        true

      true ->
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
