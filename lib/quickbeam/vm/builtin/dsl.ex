defmodule QuickBEAM.VM.Builtin.DSL do
  @moduledoc "Compiles the declarative builtin syntax into immutable validated specs."

  alias QuickBEAM.VM.Builtin.{AccessorSpec, FunctionSpec, Spec, Validator}

  @doc "Installs builtin declaration attributes and macros."
  defmacro __using__(_opts) do
    quote do
      import QuickBEAM.VM.Builtin.DSL

      Module.register_attribute(__MODULE__, :quickbeam_builtin_name, persist: false)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_options, persist: false)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_count, persist: false)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_statics, accumulate: true)
      Module.register_attribute(__MODULE__, :quickbeam_builtin_prototype, accumulate: true)
      @quickbeam_builtin_count 0
      @before_compile QuickBEAM.VM.Builtin.DSL
    end
  end

  @doc "Declares one builtin namespace, intrinsic fragment, or constructor."
  defmacro builtin(name, opts \\ [], do: block) do
    quote do
      @quickbeam_builtin_count @quickbeam_builtin_count + 1
      @quickbeam_builtin_name unquote(name)
      @quickbeam_builtin_options unquote(opts)
      unquote(block)
    end
  end

  @doc "Groups prototype declarations."
  defmacro prototype(do: block), do: block

  @doc "Declares a static function using its handler as the default JavaScript name."
  defmacro static(handler, opts \\ []) do
    spec = function_spec(handler, opts)

    quote do
      @quickbeam_builtin_statics unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a prototype method using its handler as the default JavaScript name."
  defmacro method(handler, opts \\ []) do
    spec = function_spec(handler, opts)

    quote do
      @quickbeam_builtin_prototype unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a static data property and evaluates its value in the declaring module."
  defmacro static_value(key, value, opts \\ []) do
    quote bind_quoted: [key: key, value: value, opts: opts] do
      @quickbeam_builtin_statics %QuickBEAM.VM.Builtin.PropertySpec{
        key: key,
        value: value,
        writable: Keyword.get(opts, :writable, false),
        enumerable: Keyword.get(opts, :enumerable, false),
        configurable: Keyword.get(opts, :configurable, false)
      }
    end
  end

  @doc "Declares an immutable static constant."
  defmacro constant(key, value) do
    quote bind_quoted: [key: key, value: value] do
      @quickbeam_builtin_statics %QuickBEAM.VM.Builtin.PropertySpec{
        key: key,
        value: value,
        writable: false,
        enumerable: false,
        configurable: false
      }
    end
  end

  @doc "Declares a prototype data property and evaluates its value in the declaring module."
  defmacro prototype_value(key, value, opts \\ []) do
    quote bind_quoted: [key: key, value: value, opts: opts] do
      @quickbeam_builtin_prototype %QuickBEAM.VM.Builtin.PropertySpec{
        key: key,
        value: value,
        writable: Keyword.get(opts, :writable, false),
        enumerable: Keyword.get(opts, :enumerable, false),
        configurable: Keyword.get(opts, :configurable, false)
      }
    end
  end

  @doc "Declares a prototype getter."
  defmacro getter(handler, opts \\ []) do
    spec = accessor_spec(handler, Keyword.put(opts, :get, handler))

    quote do
      @quickbeam_builtin_prototype unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a prototype getter/setter pair."
  defmacro accessor(name, opts) do
    spec = accessor_spec(name, opts)

    quote do
      @quickbeam_builtin_prototype unquote(Macro.escape(spec))
    end
  end

  @doc "Declares a static getter/setter pair."
  defmacro static_accessor(name, opts) do
    spec = accessor_spec(name, opts)

    quote do
      @quickbeam_builtin_statics unquote(Macro.escape(spec))
    end
  end

  @doc "Emits one validated immutable builtin specification."
  defmacro __before_compile__(env) do
    count = Module.get_attribute(env.module, :quickbeam_builtin_count)

    if count != 1 do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "builtin modules must contain exactly one builtin declaration"
    end

    name = Module.get_attribute(env.module, :quickbeam_builtin_name)
    opts = Module.get_attribute(env.module, :quickbeam_builtin_options) || []
    statics = env.module |> Module.get_attribute(:quickbeam_builtin_statics) |> Enum.reverse()
    prototype = env.module |> Module.get_attribute(:quickbeam_builtin_prototype) |> Enum.reverse()

    spec = %Spec{
      name: name,
      module: env.module,
      kind: Keyword.get(opts, :kind, :namespace),
      constructor: Keyword.get(opts, :constructor),
      profiles: Keyword.get(opts, :profiles, [:core]),
      depends_on: Keyword.get(opts, :depends_on, []),
      length: Keyword.get(opts, :length, 0),
      statics: statics,
      prototype: prototype
    }

    Validator.validate!(spec, env)

    quote do
      @doc "Returns this module's compile-time-validated builtin specification."
      @spec builtin_spec() :: QuickBEAM.VM.Builtin.Spec.t()
      def builtin_spec, do: unquote(Macro.escape(spec))
    end
  end

  defp function_spec(handler, opts) when is_atom(handler) and is_list(opts) do
    %FunctionSpec{
      key: Keyword.get(opts, :js, Atom.to_string(handler)),
      handler: handler,
      length: Keyword.get(opts, :length, 0),
      writable: Keyword.get(opts, :writable, true),
      enumerable: Keyword.get(opts, :enumerable, false),
      configurable: Keyword.get(opts, :configurable, true)
    }
  end

  defp accessor_spec(name, opts) when is_atom(name) and is_list(opts) do
    %AccessorSpec{
      key: Keyword.get(opts, :js, Atom.to_string(name)),
      getter: Keyword.get(opts, :get),
      setter: Keyword.get(opts, :set),
      enumerable: Keyword.get(opts, :enumerable, false),
      configurable: Keyword.get(opts, :configurable, true)
    }
  end
end
