defmodule QuickBEAM.VM.Iterator do
  @moduledoc """
  Defines the canonical iterable-value boundary used by Promise combinators.

  The current core profile supports owner-local arrays and sets, internal BEAM
  lists, and JavaScript strings. Array holes yield `undefined`, matching array
  iterator behavior. Custom Symbol iterators will extend this boundary with
  resumable invocation actions rather than adding another combinator path.
  """

  alias QuickBEAM.VM.{Execution, Heap, Object, Property, Reference}

  @doc "Collects the values produced by a supported iterable in iteration order."
  @spec values(term(), Execution.t()) :: {:ok, [term()]} | {:error, :not_iterable}
  def values(value, _execution) when is_list(value), do: {:ok, value}
  def values(value, _execution) when is_binary(value), do: {:ok, String.codepoints(value)}

  def values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length, properties: properties}} ->
        values =
          if length == 0 do
            []
          else
            for index <- 0..(length - 1), do: property_value(properties, index)
          end

        {:ok, values}

      {:ok, %Object{kind: :set, internal: %{values: values}}} ->
        {:ok, values}

      _other ->
        {:error, :not_iterable}
    end
  end

  def values(_value, _execution), do: {:error, :not_iterable}

  defp property_value(properties, index) do
    case Map.get(properties, index) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end
end
