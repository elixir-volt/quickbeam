defmodule QuickBEAM.API do
  @moduledoc """
  Defines Elixir APIs that can be loaded into a QuickBEAM runtime.

      defmodule MyApp.Tools do
        use QuickBEAM.API, scope: "tools"

        js double(n), do: n * 2

        js remember(value), runtime do
          QuickBEAM.set_global(runtime, "lastValue", value)
          value
        end
      end

      {:ok, rt} = QuickBEAM.start()
      :ok = QuickBEAM.load_api(rt, MyApp.Tools)
      {:ok, 10} = QuickBEAM.eval(rt, "tools.double(5)")

  `js/2` and `defjs/2` define normal Elixir functions and mark them for export.
  The three-argument form appends the current runtime as the final Elixir
  argument. Set `@variadic true` immediately before a definition to receive all
  JavaScript arguments as one list.
  """

  defmacro __using__(opts) do
    scope = opts |> Keyword.get(:scope, "") |> normalize_scope()

    quote do
      @behaviour QuickBEAM.API

      import QuickBEAM.API,
        only: [
          defjs: 2,
          defjs: 3,
          js: 2,
          js: 3,
          raise_js!: 2,
          is_js_object: 1,
          is_js_function: 1
        ]

      Module.register_attribute(__MODULE__, :quickbeam_function, accumulate: true)
      Module.register_attribute(__MODULE__, :variadic, persist: false)
      @before_compile QuickBEAM.API

      @impl QuickBEAM.API
      def scope, do: unquote(scope)
    end
  end

  @type function_export :: %{
          name: atom(),
          arity: non_neg_integer(),
          inject_runtime?: boolean(),
          variadic?: boolean()
        }
  @type scope_def :: [String.t()]

  @callback scope() :: scope_def()
  @callback install(QuickBEAM.API.Context.t()) ::
              :ok | {:ok, term()} | String.t() | QuickBEAM.Chunk.t()
  @callback install(QuickBEAM.runtime(), scope_def(), term()) ::
              :ok | {:ok, term()} | String.t() | QuickBEAM.Chunk.t()
  @optional_callbacks install: 1, install: 3

  defguard is_js_object(value)
           when is_tuple(value) and tuple_size(value) == 2 and elem(value, 0) == :obj

  defguard is_js_function(value)
           when (is_tuple(value) and tuple_size(value) >= 1 and
                   elem(value, 0) in [:builtin, :closure, :bound]) or
                  is_struct(value, QuickBEAM.VM.Function)

  defmacro js(fa, do: body), do: define_js(fa, false, nil, body)
  defmacro js(fa, runtime, do: body), do: define_js(fa, true, runtime, body)
  defmacro defjs(fa, do: body), do: define_js(fa, false, nil, body)
  defmacro defjs(fa, runtime, do: body), do: define_js(fa, true, runtime, body)

  defmacro __before_compile__(env) do
    functions =
      env.module
      |> Module.get_attribute(:quickbeam_function)
      |> Enum.reverse()
      |> dedupe_functions!()

    quote do
      def __quickbeam_api__ do
        %{scope: scope(), functions: unquote(Macro.escape(functions))}
      end
    end
  end

  @doc "Raises a JavaScript-shaped error from a host API function."
  @spec raise_js!(String.t(), String.t()) :: no_return()
  def raise_js!(name, message) when is_binary(name) and is_binary(message) do
    raise QuickBEAM.JS.Error, name: name, message: message
  end

  @doc false
  def register_function!(function, module, existing) do
    validate_function!(function, module, existing)
  end

  defp define_js(fa, inject_runtime?, runtime_var, body) do
    {name, arity} = function_name_arity!(fa)
    definition = if inject_runtime?, do: append_runtime_arg(fa, name, runtime_var), else: fa

    quote do
      variadic? = Module.delete_attribute(__MODULE__, :variadic) == true

      @quickbeam_function QuickBEAM.API.register_function!(
                            %{
                              name: unquote(name),
                              arity: unquote(arity),
                              inject_runtime?: unquote(inject_runtime?),
                              variadic?: variadic?
                            },
                            __MODULE__,
                            @quickbeam_function
                          )

      def unquote(definition), do: unquote(body)
    end
  end

  defp append_runtime_arg(fa, name, runtime_var) do
    {fa, _acc} =
      Macro.prewalk(fa, :ok, fn
        {^name, context, args}, acc ->
          {{name, context, List.wrap(args) ++ [runtime_var]}, acc}

        ast, acc ->
          {ast, acc}
      end)

    fa
  end

  defp validate_function!(
         %{name: name, arity: arity, inject_runtime?: inject_runtime?, variadic?: variadic?} =
           function,
         module,
         existing
       )
       when is_atom(name) and is_integer(arity) and arity >= 0 and is_boolean(inject_runtime?) and
              is_boolean(variadic?) do
    if variadic? and arity != 1 do
      raise ArgumentError,
            "variadic js #{inspect(module)}.#{name}/#{arity} must accept exactly one argument list"
    end

    conflicting_runtime? =
      Enum.any?(existing, fn
        %{name: ^name, inject_runtime?: other} -> other != inject_runtime?
        {^name, _, other} -> other != inject_runtime?
        _ -> false
      end)

    if conflicting_runtime? do
      raise ArgumentError,
            "all js clauses for #{inspect(module)}.#{name} must use the same runtime injection mode"
    end

    function
  end

  defp dedupe_functions!(functions) do
    functions
    |> Enum.reduce([], fn function, acc ->
      if Enum.any?(acc, &same_export?(&1, function)), do: acc, else: [function | acc]
    end)
    |> Enum.reverse()
  end

  defp same_export?(left, right) do
    left.name == right.name and left.arity == right.arity and
      left.inject_runtime? == right.inject_runtime? and left.variadic? == right.variadic?
  end

  defp function_name_arity!({:when, _, [call | _guards]}), do: function_name_arity!(call)

  defp function_name_arity!({name, _, args}) when is_atom(name),
    do: {name, length(List.wrap(args))}

  defp function_name_arity!(other) do
    raise ArgumentError, "js expects a function head, got: #{Macro.to_string(other)}"
  end

  defp normalize_scope(scope) when is_binary(scope), do: String.split(scope, ".", trim: true)
  defp normalize_scope(scope) when is_list(scope), do: Enum.map(scope, &to_string/1)
  defp normalize_scope(scope) when is_atom(scope), do: [Atom.to_string(scope)]
end
