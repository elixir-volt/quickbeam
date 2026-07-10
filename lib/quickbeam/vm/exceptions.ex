defmodule QuickBEAM.VM.Exceptions do
  @moduledoc """
  Converts VM-generated failures into catchable owner-local JavaScript errors.

  JavaScript values remain heap references while code can catch them. Conversion
  to `QuickBEAM.JSError` happens only after a value escapes the evaluation.
  """

  alias QuickBEAM.VM.{Builtins, Execution, Heap, Object, Reference, Thrown}

  @doc "Materializes a generated VM exception as a JavaScript heap value."
  @spec materialize(term(), Execution.t()) :: {term(), Execution.t()}
  def materialize(reason, execution) do
    case QuickBEAM.JSError.vm_exception_value(reason) do
      %{} = value when not is_struct(value) ->
        name = to_string(value[:name] || value["name"] || "Error")
        message = to_string(value[:message] || value["message"] || "")
        Builtins.new_error(execution, name, message)

      value ->
        {value, execution}
    end
  end

  @doc "Converts an uncaught JavaScript value into the stable public error struct."
  @spec to_js_error(term(), Execution.t(), [QuickBEAM.JSError.frame()]) :: QuickBEAM.JSError.t()
  def to_js_error(%Thrown{value: value, frames: async_frames}, execution, frames),
    do: to_js_error(value, execution, async_frames ++ frames)

  def to_js_error(%Reference{} = reference, execution, frames) do
    case details(reference, execution) do
      {:ok, value} -> QuickBEAM.JSError.from_vm(value, frames)
      :error -> QuickBEAM.JSError.from_vm(reference, frames)
    end
  end

  def to_js_error(reason, _execution, frames), do: QuickBEAM.JSError.from_vm(reason, frames)

  @doc "Returns the public name and message of an owner-local JavaScript error object."
  @spec details(Reference.t(), Execution.t()) :: {:ok, map()} | :error
  def details(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{internal: {:error, default_name}}} ->
        name =
          case Heap.get(execution, reference, "name") do
            {:ok, value} when value not in [:undefined, nil] -> to_string_value(value)
            _missing -> default_name
          end

        message =
          case Heap.get(execution, reference, "message") do
            {:ok, :undefined} -> ""
            {:ok, value} -> to_string_value(value)
            {:error, _reason} -> ""
          end

        {:ok, %{"name" => name, "message" => message}}

      _not_error ->
        :error
    end
  end

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value), do: QuickBEAM.VM.Value.to_string_value(value)
end
