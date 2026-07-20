defmodule QuickBEAM.VM.Runtime.Value.Export do
  @moduledoc """
  Converts owner-local JavaScript values into safe ordinary BEAM values.

  Functions and cyclic object graphs are rejected instead of leaking live VM
  references outside their evaluation process.
  """

  alias QuickBEAM.VM.Runtime.Exception
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Promise
  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.Property.Descriptor
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Symbol

  @doc "Exports one owner-local JavaScript value to a safe BEAM term."
  @spec value(term(), State.t()) :: {:ok, term()} | {:error, term()}
  def value(value, %State{} = execution), do: convert(value, execution, %{})

  @spec convert(term(), State.t(), %{optional(non_neg_integer()) => true}) ::
          {:ok, term()} | {:error, term()}
  defp convert(%PromiseReference{} = promise, execution, seen) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} -> convert(value, execution, seen)
      {:rejected, reason} -> {:error, Exception.to_js_error(reason, execution, [])}
      :pending -> {:error, :pending_promise_result}
    end
  end

  defp convert(%Reference{id: id} = reference, execution, seen) do
    if Map.has_key?(seen, id) do
      {:error, {:cyclic_result, id}}
    else
      case Heap.fetch_object(execution, reference) do
        {:ok, object} -> convert_object(object, execution, Map.put(seen, id, true))
        :error -> {:error, {:invalid_reference, id}}
      end
    end
  end

  defp convert({:closure, _function, _references}, _execution, _seen),
    do: {:error, :function_result}

  defp convert(%QuickBEAM.VM.Program.Function{}, _execution, _seen),
    do: {:error, :function_result}

  defp convert(%Symbol{}, _execution, _seen), do: {:error, :symbol_result}

  defp convert(value, execution, seen) when is_list(value) do
    convert_list(value, execution, seen, [])
  end

  defp convert(value, execution, seen) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, child}, {:ok, result} ->
      case convert(child, execution, seen) do
        {:ok, child} -> {:cont, {:ok, Map.put(result, key, child)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert(value, _execution, _seen), do: {:ok, value}

  @spec convert_object(Object.t(), State.t(), %{optional(non_neg_integer()) => true}) ::
          {:ok, term()} | {:error, term()}
  defp convert_object(%Object{callable: callable}, _execution, _seen) when not is_nil(callable),
    do: {:error, :function_result}

  defp convert_object(%Object{kind: :array} = object, execution, seen) do
    values =
      Enum.map(Heap.array_entries(object), fn
        {:present, value} -> value
        :hole -> :undefined
      end)

    convert_list(values, execution, seen, [])
  end

  defp convert_object(%Object{properties: properties}, execution, seen) do
    properties
    |> Enum.filter(fn {key, property} ->
      Object.property_enumerable?(property) and not is_struct(key, Symbol)
    end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, property}, {:ok, result} ->
      %Descriptor{value: value} = Object.property_descriptor(property)

      case convert(value, execution, seen) do
        {:ok, value} -> {:cont, {:ok, Map.put(result, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec convert_list([term()], State.t(), %{optional(non_neg_integer()) => true}, [term()]) ::
          {:ok, [term()]} | {:error, term()}
  defp convert_list([], _execution, _seen, result), do: {:ok, Enum.reverse(result)}

  defp convert_list([value | rest], execution, seen, result) do
    case convert(value, execution, seen) do
      {:ok, value} -> convert_list(rest, execution, seen, [value | result])
      {:error, reason} -> {:error, reason}
    end
  end
end
