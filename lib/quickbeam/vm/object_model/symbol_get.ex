defmodule QuickBEAM.VM.ObjectModel.SymbolGet do
  @moduledoc "Symbol-keyed property lookup helpers for ObjectModel.Get."

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.ObjectModel.FunctionPrototypeGet
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def normalize({:symbol, _, _} = key), do: PropertyKey.normalize(key)
  def normalize(key), do: key

  def callable_property(value, sym_key, callbacks) do
    if Builtin.callable?(value) do
      case callbacks.get_own.(value, sym_key) do
        :undefined ->
          FunctionPrototypeGet.fallback(
            callbacks.get_from_prototype.(value, sym_key),
            value,
            sym_key
          )

        {:accessor, getter, _} when getter != nil ->
          callbacks.call_getter.(getter, value)

        {:accessor, nil, _} ->
          :undefined

        value ->
          value
      end
    else
      callbacks.get_own.(value, sym_key)
    end
  end

  def property(value, sym_key, callbacks, receiver \\ nil) do
    receiver = receiver || value

    case callbacks.get_own.(value, sym_key) do
      :undefined -> missing_own_property(value, sym_key, callbacks, receiver)
      {:accessor, getter, _} when getter != nil -> callbacks.call_getter.(getter, receiver)
      value -> value
    end
  end

  defp missing_own_property(value, sym_key, callbacks, receiver) do
    if callbacks.explicit_own?.(value, sym_key) do
      :undefined
    else
      case callbacks.get_from_prototype.(value, sym_key) do
        {:accessor, getter, _} when getter != nil -> callbacks.call_getter.(getter, receiver)
        {:accessor, nil, _} -> :undefined
        value -> value
      end
    end
  end
end
