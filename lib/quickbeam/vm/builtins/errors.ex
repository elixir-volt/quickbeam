defmodule QuickBEAM.VM.Builtins.ErrorSupport do
  @moduledoc "Provides shared declarative Error constructor and formatting semantics."

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Builtins, Heap, Object, Properties, Reference, Value}

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
      {error, execution} = Builtins.new_error(execution, name, message)
      {:ok, error, execution}
    end
  end

  @doc "Formats an Error receiver according to `Error.prototype.toString`."
  def to_string(%Call{this: %Reference{} = error, execution: execution}) do
    with {:ok, name} <- Properties.get(error, "name", execution),
         {:ok, message} <- Properties.get(error, "message", execution) do
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
      Properties.define(error, "message", message, execution,
        enumerable: false,
        configurable: true,
        writable: true
      )

    execution
  end
end

defmodule QuickBEAM.VM.Builtins.Error do
  @moduledoc "Defines the declarative JavaScript Error constructor and prototype."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtins.ErrorSupport

  builtin "Error",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"],
    prototype_parent: "Object",
    prototype_role: {:error, "Error"} do
    prototype do
      prototype_value "name", "Error", writable: true, configurable: true
      prototype_value "message", "", writable: true, configurable: true
      method :to_string_method, js: "toString", length: 0
    end
  end

  @doc "Constructs an Error value."
  def construct(%Call{} = call), do: ErrorSupport.construct("Error", call)

  @doc "Formats an Error value."
  def to_string_method(%Call{} = call), do: ErrorSupport.to_string(call)
end

defmodule QuickBEAM.VM.Builtins.ErrorSubclass do
  @moduledoc "Generates one declarative native Error subclass builtin."

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      use QuickBEAM.VM.Builtin

      alias QuickBEAM.VM.Builtin.Call
      alias QuickBEAM.VM.Builtins.ErrorSupport

      @error_name unquote(name)

      builtin unquote(name),
        kind: :constructor,
        constructor: :construct,
        length: 1,
        depends_on: ["Error", "Function"],
        prototype_parent: "Error",
        prototype_role: {:error, unquote(name)} do
        prototype do
          prototype_value "name", unquote(name), writable: true, configurable: true
          prototype_value "message", "", writable: true, configurable: true
        end
      end

      @doc "Constructs this native Error subclass."
      def construct(%Call{} = call), do: ErrorSupport.construct(@error_name, call)
    end
  end
end

defmodule QuickBEAM.VM.Builtins.EvalError do
  @moduledoc "Defines the declarative EvalError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "EvalError"
end

defmodule QuickBEAM.VM.Builtins.RangeError do
  @moduledoc "Defines the declarative RangeError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "RangeError"
end

defmodule QuickBEAM.VM.Builtins.ReferenceError do
  @moduledoc "Defines the declarative ReferenceError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "ReferenceError"
end

defmodule QuickBEAM.VM.Builtins.SyntaxError do
  @moduledoc "Defines the declarative SyntaxError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "SyntaxError"
end

defmodule QuickBEAM.VM.Builtins.TypeError do
  @moduledoc "Defines the declarative TypeError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "TypeError"
end

defmodule QuickBEAM.VM.Builtins.URIError do
  @moduledoc "Defines the declarative URIError constructor."
  use QuickBEAM.VM.Builtins.ErrorSubclass, name: "URIError"
end
