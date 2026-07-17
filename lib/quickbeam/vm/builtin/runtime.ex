defmodule QuickBEAM.VM.Builtin.Runtime do
  @moduledoc """
  Installs and dispatches the JavaScript built-ins supported by the VM profile.
  """

  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.RegExp
  alias QuickBEAM.VM.Runtime.Value

  alias QuickBEAM.VM.Builtin.Installer
  alias QuickBEAM.VM.Builtin.Registry

  @doc "Installs all builtins enabled by an immutable runtime profile."
  @spec install(State.t(), :core | :ssr) :: State.t()
  def install(execution, profile \\ :core),
    do: Installer.install_all(execution, Registry.modules(profile), profile)

  @doc "Returns the callable token stored on an object reference, if present."
  @spec callable(State.t(), Reference.t()) :: term() | nil
  def callable(execution, %Reference{} = reference) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{callable: callable}} -> callable
      :error -> nil
    end
  end

  @doc "Allocates a catchable JavaScript error object in the current evaluation heap."
  @spec new_error(State.t(), String.t(), String.t() | nil) :: {Reference.t(), State.t()}
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
          Property.define(error, "message", message, execution,
            enumerable: false,
            configurable: true,
            writable: true
          )

        execution
      end

    {error, execution}
  end

  @doc "Dispatches a primitive builtin method through canonical runtime semantics."
  @spec call(term(), term(), [term()], State.t()) ::
          {:ok, term(), State.t()} | {:error, term(), State.t()}
  def call(
        {:primitive_method, :regexp, "exec"},
        %Reference{} = reference,
        [value | _],
        execution
      ) do
    with {:ok, %Object{kind: :regexp, internal: %RegExp{} = regexp}} <-
           Heap.fetch_object(execution, reference),
         {:ok, regex} <- compile_regexp(regexp) do
      case Regex.run(regex, Value.to_string_value(value), return: :index) do
        [{index, length} | _captures] ->
          matched = value |> Value.to_string_value() |> binary_part(index, length)
          {result, execution} = Heap.allocate(execution, :array)
          {:ok, execution} = Property.define(result, 0, matched, execution)
          {:ok, execution} = Property.define(result, "index", index, execution)
          {:ok, result, execution}

        nil ->
          {:ok, nil, execution}
      end
    else
      _other -> {:error, :incompatible_regexp_receiver, execution}
    end
  end

  def call(
        {:primitive_method, :regexp, "test"},
        %Reference{} = reference,
        [value | _],
        execution
      ) do
    with {:ok, %Object{kind: :regexp, internal: %RegExp{} = regexp}} <-
           Heap.fetch_object(execution, reference),
         {:ok, last_index} <- Property.get(reference, "lastIndex", execution) do
      {matched?, next_index} =
        regex_match_from(regexp, Value.to_string_value(value), last_index)

      {:ok, execution} = Property.put(reference, "lastIndex", next_index, execution)
      {:ok, matched?, execution}
    else
      _other -> {:error, :incompatible_regexp_receiver, execution}
    end
  end

  def call({:primitive_method, :regexp, "test"}, %RegExp{} = regexp, [value | _], execution),
    do: {:ok, regex_match?(regexp, Value.to_string_value(value)), execution}

  def call(callable, _this, _arguments, execution),
    do: {:error, {:unsupported_builtin, callable}, execution}

  defp regex_match_from(%RegExp{} = regexp, value, last_index) do
    stateful? = regexp_flag?(regexp, 1) or regexp_flag?(regexp, 32)
    current_index = if is_integer(last_index) and last_index >= 0, do: last_index, else: 0
    start = if stateful?, do: current_index, else: 0

    case compile_regexp(regexp) do
      {:ok, regex} ->
        case Regex.run(regex, value, offset: start, return: :index) do
          [{index, length} | _captures] ->
            next_index = if stateful?, do: index + max(length, 1), else: current_index
            {true, next_index}

          nil ->
            {false, if(stateful?, do: 0, else: current_index)}
        end

      {:error, _reason} ->
        {false, if(stateful?, do: 0, else: current_index)}
    end
  end

  defp regex_match?(%RegExp{} = regexp, value) do
    case compile_regexp(regexp) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp compile_regexp(%RegExp{source: source} = regexp) do
    options =
      ""
      |> maybe_regex_option(regexp_flag?(regexp, 2), "i")
      |> maybe_regex_option(regexp_flag?(regexp, 4), "m")
      |> maybe_regex_option(regexp_flag?(regexp, 8), "s")

    Regex.compile(source, options)
  end

  defp regexp_flag?(%RegExp{bytecode: <<flags, _rest::binary>>}, flag),
    do: Bitwise.band(flags, flag) != 0

  defp regexp_flag?(_regexp, _flag), do: false

  defp maybe_regex_option(options, true, option), do: options <> option
  defp maybe_regex_option(options, false, _option), do: options
end
