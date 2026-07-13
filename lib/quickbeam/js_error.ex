defmodule QuickBEAM.JSError do
  @moduledoc """
  Represents an uncaught JavaScript exception at a QuickBEAM API boundary.

  Errors include stable JavaScript source locations and structured JavaScript
  frames without exposing Elixir handler stack traces.
  """

  defexception [:message, :name, :stack, :filename, :line, :column, frames: []]

  @type frame :: %{
          function: String.t(),
          filename: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          stack: String.t() | nil,
          filename: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          frames: [frame()]
        }

  @impl true
  def message(%__MODULE__{name: name, message: msg}) do
    "#{name}: #{msg}"
  end

  @doc "Converts a JavaScript error value returned by the native runtime."
  def from_js_value(value) when is_map(value) do
    %__MODULE__{
      message: to_string(value[:message] || value["message"] || inspect(value)),
      name: to_string(value[:name] || value["name"] || "Error"),
      stack: get_stack(value),
      filename: value[:filename] || value["filename"],
      line: value[:line] || value["line"],
      column: value[:column] || value["column"],
      frames: value[:frames] || value["frames"] || []
    }
  end

  def from_js_value(value) when is_binary(value) do
    %__MODULE__{message: value, name: "Error", stack: nil}
  end

  def from_js_value(value) do
    %__MODULE__{message: inspect(value), name: "Error", stack: nil}
  end

  @doc "Converts a VM-generated exception reason into a catchable JavaScript value."
  def vm_exception_value(reason)
      when is_tuple(reason) and
             elem(reason, 0) in [
               :handler_exception,
               :not_callable,
               :range_error,
               :reference_error,
               :type_error,
               :unknown_handler
             ] do
    {name, message} = vm_name_and_message(reason)
    %{"name" => name, "message" => message}
  end

  def vm_exception_value(reason), do: reason

  @doc "Builds an exception from an uncaught VM value and JavaScript stack frames."
  @spec from_vm(term(), [frame()]) :: t()
  def from_vm(%QuickBEAM.VM.Thrown{value: value, frames: async_frames}, frames),
    do: from_vm(value, async_frames ++ frames)

  def from_vm(reason, frames) do
    {name, message} = vm_name_and_message(reason)
    first = List.first(frames) || %{}

    %__MODULE__{
      name: name,
      message: message,
      filename: first[:filename],
      line: first[:line],
      column: first[:column],
      frames: frames,
      stack: format_stack(name, message, frames)
    }
  end

  defp vm_name_and_message(%__MODULE__{} = error), do: {error.name, error.message}

  defp vm_name_and_message(%{} = value) when not is_struct(value) do
    {
      to_string(value[:name] || value["name"] || "Error"),
      to_string(value[:message] || value["message"] || inspect(value))
    }
  end

  defp vm_name_and_message({:type_error, reason}), do: {"TypeError", format_reason(reason)}
  defp vm_name_and_message({:range_error, reason}), do: {"RangeError", format_reason(reason)}

  defp vm_name_and_message({:reference_error, name}) when is_binary(name),
    do: {"ReferenceError", "#{name} is not defined"}

  defp vm_name_and_message({:reference_error, binding}),
    do:
      {"ReferenceError",
       "Cannot access lexical binding #{inspect(binding)} before initialization"}

  defp vm_name_and_message({:not_callable, value}),
    do: {"TypeError", "#{inspect(value)} is not a function"}

  defp vm_name_and_message({:unknown_handler, name}),
    do: {"Error", "Unknown BEAM handler #{inspect(name)}"}

  defp vm_name_and_message({:handler_exception, exception, _stacktrace}),
    do: {"Error", Exception.message(exception)}

  defp vm_name_and_message(reason), do: {"Error", format_reason(reason)}

  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason(reason), do: inspect(reason)

  defp format_stack(name, message, []), do: "#{name}: #{message}"

  defp format_stack(name, message, frames) do
    rendered =
      Enum.map_join(frames, "\n", fn frame ->
        function = frame.function || "<anonymous>"
        filename = frame.filename || "<eval>"
        line = frame.line || 1
        column = frame.column || 1
        "    at #{function} (#{filename}:#{line}:#{column})"
      end)

    "#{name}: #{message}\n#{rendered}"
  end

  defp get_stack(value) do
    case value[:stack] || value["stack"] do
      nil -> nil
      stack -> to_string(stack)
    end
  end
end
