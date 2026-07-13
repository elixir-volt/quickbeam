defmodule QuickBEAM.VM.Builtins do
  @moduledoc """
  Installs and dispatches the JavaScript built-ins supported by the VM profile.
  """

  alias QuickBEAM.VM.{
    Execution,
    Heap,
    Object,
    Properties,
    Reference,
    RegExp,
    Value
  }

  alias QuickBEAM.VM.Builtin.{Installer, Registry}

  @spec install(Execution.t()) :: Execution.t()
  def install(execution), do: Installer.install_all(execution, Registry.modules(:core))

  @spec callable(Execution.t(), Reference.t()) :: term() | nil
  def callable(execution, %Reference{} = reference) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{callable: callable}} -> callable
      :error -> nil
    end
  end

  @doc "Allocates a catchable JavaScript error object in the current evaluation heap."
  @spec new_error(Execution.t(), String.t(), String.t() | nil) :: {Reference.t(), Execution.t()}
  def new_error(execution, name, message) do
    prototype =
      Map.get(execution.error_prototypes, name) || Map.get(execution.error_prototypes, "Error")

    {error, execution} =
      Heap.allocate(execution, :ordinary, prototype: prototype, internal: {:error, name})

    execution =
      if is_nil(message) do
        execution
      else
        {:ok, execution} =
          Properties.define(error, "message", message, execution,
            enumerable: false,
            configurable: true,
            writable: true
          )

        execution
      end

    {error, execution}
  end

  @spec call(term(), term(), [term()], Execution.t()) ::
          {:ok, term(), Execution.t()} | {:error, term(), Execution.t()}
  def call({:primitive_method, :regexp, "test"}, %RegExp{} = regexp, [value | _], execution),
    do: {:ok, regex_match?(regexp, Value.to_string_value(value)), execution}

  def call(callable, _this, _arguments, execution),
    do: {:error, {:unsupported_builtin, callable}, execution}

  defp regex_match?(%RegExp{source: source}, value) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end
end
