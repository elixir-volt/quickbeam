defmodule QuickBEAM.VM.Builtin do
  @moduledoc """
  Provides the declarative DSL and runtime dispatcher for JavaScript builtins.

  Declarations compile into immutable `QuickBEAM.VM.Builtin.Spec` values. An
  explicit registry installs those specs into each execution; no application
  module discovery or process-global mutable state is used.

      defmodule MathBuiltin do
        use QuickBEAM.VM.Builtin

        builtin "Math", kind: :object do
          static "floor", :floor, length: 1
        end

        def floor(%QuickBEAM.VM.Builtin.Call{} = call), do: ...
      end
  """

  alias QuickBEAM.VM.Builtin.{Call, FunctionSpec, PropertySpec, Spec}

  @type handler_result ::
          {:ok, term(), QuickBEAM.VM.Execution.t()}
          | {:error, term(), QuickBEAM.VM.Execution.t()}
          | {:action, term()}

  @doc "Installs the builtin declaration macros in a module."
  defmacro __using__(_opts) do
    quote do
      import QuickBEAM.VM.Builtin,
        only: [
          builtin: 2,
          builtin: 3,
          prototype: 1,
          static: 2,
          static: 3,
          method: 2,
          method: 3,
          static_value: 2,
          static_value: 3,
          prototype_value: 2,
          prototype_value: 3
        ]

      Module.register_attribute(__MODULE__, :quickbeam_builtin_name, persist: false)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_options, persist: false)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_statics, accumulate: true)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_prototype, accumulate: true)
      @before_compile QuickBEAM.VM.Builtin
    end
  end

  @doc "Declares a builtin and its static or prototype entries."
  defmacro builtin(name, opts \\ [], do: block) do
    quote do
      @quickbeam_builtin_name unquote(name)
      @quickbeam_builtin_options unquote(opts)
      unquote(block)
    end
  end

  @doc "Groups prototype method or value declarations."
  defmacro prototype(do: block), do: block

  @doc "Declares a static builtin function."
  defmacro static(key, handler, opts \\ []) do
    spec = function_spec(key, handler, opts)

    quote do
      @quickbeam_builtin_statics unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a prototype builtin function."
  defmacro method(key, handler, opts \\ []) do
    spec = function_spec(key, handler, opts)

    quote do
      @quickbeam_builtin_prototype unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a static data property."
  defmacro static_value(key, value, opts \\ []) do
    spec = property_spec(key, value, opts)

    quote do
      @quickbeam_builtin_statics unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a prototype data property."
  defmacro prototype_value(key, value, opts \\ []) do
    spec = property_spec(key, value, opts)

    quote do
      @quickbeam_builtin_prototype unquote(Macro.escape(spec))
    end
  end

  @doc "Returns whether a declarative builtin token is its spec's constructor."
  @spec constructable?({:declared_builtin, module(), atom()}) :: boolean()
  def constructable?({:declared_builtin, module, handler}) do
    spec = module.builtin_spec()
    spec.kind == :constructor and spec.constructor == handler
  end

  @doc "Dispatches a stable declarative builtin token to its module handler."
  @spec invoke({:declared_builtin, module(), atom()}, Call.t()) :: handler_result()
  def invoke({:declared_builtin, module, handler}, %Call{} = call),
    do: apply(module, handler, [call])

  @doc "Emits and validates a module's immutable builtin specification."
  defmacro __before_compile__(env) do
    name = Module.get_attribute(env.module, :quickbeam_builtin_name)
    opts = Module.get_attribute(env.module, :quickbeam_builtin_options) || []
    statics = env.module |> Module.get_attribute(:quickbeam_builtin_statics) |> Enum.reverse()
    prototype = env.module |> Module.get_attribute(:quickbeam_builtin_prototype) |> Enum.reverse()

    spec = %Spec{
      name: name,
      module: env.module,
      kind: Keyword.get(opts, :kind, :object),
      constructor: Keyword.get(opts, :constructor),
      profile: Keyword.get(opts, :profile, :core),
      length: Keyword.get(opts, :length, 0),
      statics: statics,
      prototype: prototype
    }

    validate!(spec, env)

    quote do
      @doc "Returns this module's compile-time-validated builtin specification."
      @spec builtin_spec() :: QuickBEAM.VM.Builtin.Spec.t()
      def builtin_spec, do: unquote(Macro.escape(spec))
    end
  end

  defp function_spec(key, handler, opts) do
    %FunctionSpec{
      key: key,
      handler: handler,
      length: Keyword.get(opts, :length, 0),
      writable: Keyword.get(opts, :writable, true),
      enumerable: Keyword.get(opts, :enumerable, false),
      configurable: Keyword.get(opts, :configurable, true)
    }
  end

  defp property_spec(key, value, opts) do
    %PropertySpec{
      key: key,
      value: value,
      writable: Keyword.get(opts, :writable, false),
      enumerable: Keyword.get(opts, :enumerable, false),
      configurable: Keyword.get(opts, :configurable, false)
    }
  end

  defp validate!(%Spec{} = spec, env) do
    unless is_binary(spec.name) and spec.name != "" do
      compile_error!(env, "builtin name must be a non-empty string")
    end

    unless spec.kind in [:object, :constructor, :extension] do
      compile_error!(env, "unsupported builtin kind: #{inspect(spec.kind)}")
    end

    unless is_integer(spec.length) and spec.length >= 0 do
      compile_error!(env, "builtin length must be a non-negative integer")
    end

    if spec.kind == :constructor and not is_atom(spec.constructor) do
      compile_error!(env, "constructor builtins require a :constructor handler")
    end

    entries = spec.statics ++ spec.prototype
    duplicate_keys!(spec.statics, :static, env)
    duplicate_keys!(spec.prototype, :prototype, env)

    handlers =
      entries
      |> Enum.filter(&is_struct(&1, FunctionSpec))
      |> Enum.map(& &1.handler)
      |> then(fn handlers ->
        if spec.constructor, do: [spec.constructor | handlers], else: handlers
      end)

    Enum.each(handlers, fn handler ->
      unless is_atom(handler) and Module.defines?(env.module, {handler, 1}, :def) do
        compile_error!(env, "builtin handler #{inspect(handler)}/1 must be a public function")
      end
    end)

    Enum.each(entries, fn
      %FunctionSpec{length: length} when is_integer(length) and length >= 0 ->
        :ok

      %FunctionSpec{key: key} ->
        compile_error!(env, "invalid function length for #{inspect(key)}")

      %PropertySpec{} ->
        :ok
    end)
  end

  defp duplicate_keys!(entries, namespace, env) do
    keys = Enum.map(entries, & &1.key)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      duplicates ->
        compile_error!(env, "duplicate #{namespace} keys: #{inspect(Enum.uniq(duplicates))}")
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
