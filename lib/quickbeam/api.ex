defmodule QuickBEAM.API do
  @moduledoc """
  Defines Elixir APIs that can be loaded into a QuickBEAM runtime.

      defmodule MyApp.Tools do
        use QuickBEAM.API, scope: "tools"

        defjs double(n), do: n * 2
      end

      {:ok, rt} = QuickBEAM.start()
      :ok = QuickBEAM.load_api(rt, MyApp.Tools)
      {:ok, 10} = QuickBEAM.eval(rt, "tools.double(5)")

  `defjs/2` defines a normal Elixir function and marks it for export. `defjs/3`
  appends the current runtime as the final argument, which is useful for APIs that
  need to read or mutate runtime state.
  """

  defmacro __using__(opts) do
    scope = opts |> Keyword.get(:scope, "") |> normalize_scope()

    quote do
      @behaviour QuickBEAM.API

      import QuickBEAM.API,
        only: [defjs: 2, defjs: 3, validate_func!: 3, is_js_object: 1, is_js_function: 1]

      Module.register_attribute(__MODULE__, :quickbeam_function, accumulate: true)
      @before_compile QuickBEAM.API

      @impl QuickBEAM.API
      def scope, do: unquote(scope)
    end
  end

  @type scope_def :: [String.t()]
  @callback scope() :: scope_def()
  @callback install(QuickBEAM.runtime(), scope_def(), term()) ::
              :ok | {:ok, term()} | String.t() | QuickBEAM.Chunk.t()
  @optional_callbacks install: 3

  defguard is_js_object(value)
           when is_tuple(value) and tuple_size(value) == 2 and elem(value, 0) == :obj

  defguard is_js_function(value)
           when (is_tuple(value) and tuple_size(value) >= 1 and
                   elem(value, 0) in [:builtin, :closure, :bound]) or
                  is_struct(value, QuickBEAM.VM.Function)

  defmacro defjs(fa, do: body) do
    {name, arity} = function_name_arity!(fa)

    quote do
      @quickbeam_function validate_func!(
                            {unquote(name), unquote(arity), false},
                            __MODULE__,
                            @quickbeam_function
                          )
      def unquote(fa), do: unquote(body)
    end
  end

  defmacro defjs(fa, state, do: body) do
    {name, arity} = function_name_arity!(fa)

    {fa, _acc} =
      Macro.prewalk(fa, :ok, fn
        {^name, context, args}, acc -> {{name, context, List.wrap(args) ++ [state]}, acc}
        ast, acc -> {ast, acc}
      end)

    quote do
      @quickbeam_function validate_func!(
                            {unquote(name), unquote(arity), true},
                            __MODULE__,
                            @quickbeam_function
                          )
      def unquote(fa), do: unquote(body)
    end
  end

  defmacro __before_compile__(env) do
    functions = Module.get_attribute(env.module, :quickbeam_function) |> Enum.reverse()

    quote do
      def __quickbeam_api__ do
        %{scope: scope(), functions: unquote(Macro.escape(functions))}
      end
    end
  end

  def validate_func!({name, arity, with_runtime?}, module, existing)
      when is_atom(name) and is_integer(arity) and arity >= 0 and is_boolean(with_runtime?) do
    exported_arity = if with_runtime?, do: arity + 1, else: arity

    if Enum.any?(existing, fn {existing_name, _, _} -> existing_name == name end) do
      raise ArgumentError, "duplicate defjs #{inspect(module)}.#{name}/#{arity}"
    end

    {name, arity, with_runtime? || exported_arity != arity}
  end

  defp function_name_arity!({:when, _, [call | _guards]}), do: function_name_arity!(call)

  defp function_name_arity!({name, _, args}) when is_atom(name),
    do: {name, length(List.wrap(args))}

  defp function_name_arity!(other) do
    raise ArgumentError, "defjs expects a function head, got: #{Macro.to_string(other)}"
  end

  defp normalize_scope(scope) when is_binary(scope), do: String.split(scope, ".", trim: true)
  defp normalize_scope(scope) when is_list(scope), do: Enum.map(scope, &to_string/1)
  defp normalize_scope(scope) when is_atom(scope), do: [Atom.to_string(scope)]
end
