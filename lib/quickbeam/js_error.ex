defmodule QuickBEAM.JSError do
  defexception [:message, :name, :stack]

  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          stack: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{name: name, message: msg}) do
    "#{name}: #{msg}"
  end

  @doc false
  def from_js_value(value) when is_map(value) do
    %__MODULE__{
      message: to_string(value[:message] || value["message"] || inspect(value)),
      name: to_string(value[:name] || value["name"] || "Error"),
      stack: get_stack(value)
    }
  end

  def from_js_value(value) when is_binary(value) do
    %__MODULE__{message: value, name: "Error", stack: nil}
  end

  def from_js_value(value) do
    %__MODULE__{message: inspect(value), name: "Error", stack: nil}
  end

  defp get_stack(value) do
    case value[:stack] || value["stack"] do
      nil -> nil
      s -> to_string(s)
    end
  end
end
