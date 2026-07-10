defmodule QuickBEAM.VM.Export do
  @moduledoc """
  Converts owner-local JavaScript values into safe ordinary BEAM values.

  Functions and cyclic object graphs are rejected instead of leaking live VM
  references outside their evaluation process.
  """

  alias QuickBEAM.VM.{Execution, Heap, Object, Promise, PromiseReference, Property, Reference}

  @spec value(term(), Execution.t()) :: {:ok, term()} | {:error, term()}
  def value(value, %Execution{} = execution), do: convert(value, execution, MapSet.new())

  defp convert(%PromiseReference{} = promise, execution, seen) do
    case Promise.state(execution, promise) do
      {:fulfilled, value} -> convert(value, execution, seen)
      {:rejected, reason} -> {:error, QuickBEAM.JSError.from_vm(reason, [])}
      :pending -> {:error, :pending_promise_result}
    end
  end

  defp convert(%Reference{id: id} = reference, execution, seen) do
    if MapSet.member?(seen, id) do
      {:error, {:cyclic_result, id}}
    else
      case Heap.fetch_object(execution, reference) do
        {:ok, object} -> convert_object(object, execution, MapSet.put(seen, id))
        :error -> {:error, {:invalid_reference, id}}
      end
    end
  end

  defp convert({:closure, _function, _references}, _execution, _seen),
    do: {:error, :function_result}

  defp convert(%QuickBEAM.VM.Function{}, _execution, _seen), do: {:error, :function_result}

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

  defp convert_object(%Object{callable: callable}, _execution, _seen) when not is_nil(callable),
    do: {:error, :function_result}

  defp convert_object(
         %Object{kind: :array, length: length, properties: properties},
         execution,
         seen
       ) do
    values =
      if length == 0 do
        []
      else
        for index <- 0..(length - 1), do: property_value(properties, index)
      end

    convert_list(values, execution, seen, [])
  end

  defp convert_object(%Object{properties: properties}, execution, seen) do
    properties
    |> Enum.filter(fn {_key, property} -> property.enumerable end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, %Property{value: value}}, {:ok, result} ->
      case convert(value, execution, seen) do
        {:ok, value} -> {:cont, {:ok, Map.put(result, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp convert_list([], _execution, _seen, result), do: {:ok, Enum.reverse(result)}

  defp convert_list([value | rest], execution, seen, result) do
    case convert(value, execution, seen) do
      {:ok, value} -> convert_list(rest, execution, seen, [value | result])
      {:error, reason} -> {:error, reason}
    end
  end

  defp property_value(properties, key) do
    case Map.get(properties, key) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end
end
