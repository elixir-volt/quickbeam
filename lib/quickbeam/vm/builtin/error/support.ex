defmodule QuickBEAM.VM.Builtin.Error.Support do
  @moduledoc "Provides shared declarative Error constructor and formatting semantics."

  alias QuickBEAM.VM.Builtin.{Call, Runtime}
  alias QuickBEAM.VM.Runtime.{Heap, Object, Property, Reference, Value}

  @doc "Constructs or initializes one Error hierarchy instance."
  def construct(name, %Call{this: this, arguments: arguments, execution: execution}) do
    message =
      case arguments do
        [value | _] -> Value.to_string_value(value)
        [] -> nil
      end

    if constructor_instance?(this, execution) do
      prototype = Map.fetch!(execution.error_prototypes, name)

      {:ok, execution} =
        Heap.update_object(execution, this, fn object ->
          %{object | prototype: prototype, internal: {:error, name}}
        end)

      execution = define_message(this, message, execution)
      {:ok, this, execution}
    else
      {error, execution} = Runtime.new_error(execution, name, message)
      {:ok, error, execution}
    end
  end

  @doc "Formats an Error receiver according to `Error.prototype.toString`."
  def to_string(%Call{this: %Reference{} = error, execution: execution}) do
    with {:ok, name} <- Property.get(error, "name", execution),
         {:ok, message} <- Property.get(error, "message", execution) do
      name = if name in [:undefined, nil], do: "Error", else: Value.to_string_value(name)
      message = if message in [:undefined, nil], do: "", else: Value.to_string_value(message)

      result =
        cond do
          name == "" -> message
          message == "" -> name
          true -> name <> ": " <> message
        end

      {:ok, result, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def to_string(%Call{execution: execution}),
    do: {:error, :incompatible_error_receiver, execution}

  defp constructor_instance?(%Reference{} = receiver, execution) do
    match?(
      {:ok, %Object{internal: :constructor_instance}},
      Heap.fetch_object(execution, receiver)
    )
  end

  defp constructor_instance?(_receiver, _execution), do: false

  defp define_message(_error, nil, execution), do: execution

  defp define_message(error, message, execution) do
    {:ok, execution} =
      Property.define(error, "message", message, execution,
        enumerable: false,
        configurable: true,
        writable: true
      )

    execution
  end
end
