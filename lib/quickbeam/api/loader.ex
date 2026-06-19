defmodule QuickBEAM.API.Loader do
  @moduledoc false

  alias QuickBEAM.API.Context
  alias QuickBEAM.Chunk
  alias QuickBEAM.Runtime
  alias QuickBEAM.VM.Heap

  @type load_result :: :ok | {:error, term()}

  @spec load(QuickBEAM.runtime(), module(), term(), keyword()) :: load_result()
  def load(runtime, module, data \\ nil, opts \\ []) when is_atom(module) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :__quickbeam_api__, 0) do
      raise ArgumentError, "#{inspect(module)} does not use QuickBEAM.API"
    end

    %{scope: module_scope, functions: functions} = module.__quickbeam_api__()
    scope = opts |> Keyword.get(:scope, module_scope) |> normalize_scope()
    previous_handlers = Runtime.handlers(runtime)
    handlers = handlers(runtime, module, functions)

    try do
      with :ok <- Runtime.install_beam_bridge(runtime),
           {:ok, _} <- QuickBEAM.eval(runtime, scope_init_source(scope), opts),
           :ok <- Runtime.merge_handlers(runtime, handlers),
           :ok <- invalidate_handler_cache(),
           :ok <- install_callback(runtime, module, scope, data, opts),
           {:ok, _} <- QuickBEAM.eval(runtime, exports_source(scope, module, functions), opts) do
        :ok
      else
        {:error, _} = error ->
          rollback_handlers(runtime, previous_handlers)
          error

        other ->
          rollback_handlers(runtime, previous_handlers)
          {:error, other}
      end
    rescue
      error ->
        rollback_handlers(runtime, previous_handlers)
        reraise error, __STACKTRACE__
    end
  end

  defp handlers(runtime, module, functions) do
    functions
    |> Enum.group_by(& &1.name)
    |> Map.new(fn {name, exports} ->
      {handler_name(module, name), handler(runtime, module, name, exports)}
    end)
  end

  defp handler(runtime, module, name, exports) do
    fn args ->
      try do
        dispatch(runtime, module, name, exports, List.wrap(args))
      rescue
        error in QuickBEAM.JS.Error -> api_error(error)
      end
    end
  end

  defp dispatch(runtime, module, name, exports, args) do
    case matching_export(exports, args) do
      nil ->
        raise ArgumentError,
              "#{inspect(module)}.#{name} expected #{expected_arities(exports)} JavaScript argument(s), got #{length(args)}"

      %{inject_runtime?: true, variadic?: true} ->
        apply(module, name, [args, runtime])

      %{inject_runtime?: true} ->
        apply(module, name, args ++ [runtime])

      %{variadic?: true} ->
        apply(module, name, [args])

      _ ->
        apply(module, name, args)
    end
  end

  defp matching_export(exports, args) do
    Enum.find(exports, fn
      %{variadic?: true} -> true
      %{arity: arity} -> arity == length(args)
    end)
  end

  defp expected_arities(exports) do
    if Enum.any?(exports, & &1.variadic?) do
      "any number of"
    else
      exports
      |> Enum.map(& &1.arity)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(" or ", &Integer.to_string/1)
    end
  end

  defp install_callback(runtime, module, scope, data, opts) do
    cond do
      function_exported?(module, :install, 1) ->
        %Context{runtime: runtime, scope: scope, data: data, opts: opts}
        |> module.install()
        |> eval_install_return(runtime)

      function_exported?(module, :install, 3) ->
        module.install(runtime, scope, data)
        |> eval_install_return(runtime)

      true ->
        :ok
    end
  end

  defp eval_install_return(:ok, _runtime), do: :ok
  defp eval_install_return({:ok, _}, _runtime), do: :ok

  defp eval_install_return(%Chunk{} = chunk, runtime),
    do: QuickBEAM.eval(runtime, chunk) |> ok_result()

  defp eval_install_return(source, runtime) when is_binary(source),
    do: QuickBEAM.eval(runtime, source) |> ok_result()

  defp eval_install_return(other, _runtime), do: {:error, {:invalid_api_install_return, other}}

  defp ok_result({:ok, _}), do: :ok
  defp ok_result({:error, _} = error), do: error

  defp scope_init_source(scope) do
    {init_lines, _target} = scope_target(scope)
    Enum.join(init_lines, "\n")
  end

  defp exports_source(scope, module, functions) do
    {_init_lines, target} = scope_target(scope)

    functions
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.map_join("\n", fn name ->
      js_name = Jason.encode!(Atom.to_string(name))
      handler = Jason.encode!(handler_name(module, name))

      target <>
        "[" <>
        js_name <>
        "] = (...args) => { const value = Beam.callSync(" <>
        handler <>
        ", ...args); if (value && typeof value === 'object' && value.__quickbeam_api_error__ === true) { const Ctor = globalThis[value.name]; const error = typeof Ctor === 'function' ? new Ctor(value.message) : new Error(value.message); error.name = value.name || error.name; if (value.stack) error.stack = value.stack; throw error; } return value; };"
    end)
  end

  defp scope_target([]), do: {[], "globalThis"}

  defp scope_target(scope) do
    {_path, lines, target} =
      Enum.reduce(scope, {"globalThis", [], "globalThis"}, fn segment, {path, lines, _target} ->
        key = Jason.encode!(segment)
        next = path <> "[" <> key <> "]"

        line =
          "if (!Object.prototype.hasOwnProperty.call(#{path}, #{key}) || " <>
            "#{next} === null || (typeof #{next} !== 'object' && typeof #{next} !== 'function')) " <>
            "#{next} = {};"

        {next, lines ++ [line], next}
      end)

    {lines, target}
  end

  defp handler_name(module, name), do: "__quickbeam_api__:#{inspect(module)}:#{name}"

  defp api_error(%QuickBEAM.JS.Error{} = error) do
    %{
      "__quickbeam_api_error__" => true,
      "name" => error.name || "Error",
      "message" => error.message || "",
      "stack" => error.stack
    }
  end

  defp normalize_scope(scope) when is_binary(scope),
    do: scope |> String.split(".", trim: true) |> reject_unsafe_scope!()

  defp normalize_scope(scope) when is_list(scope),
    do: scope |> Enum.map(&to_string/1) |> reject_unsafe_scope!()

  defp normalize_scope(scope) when is_atom(scope),
    do: [Atom.to_string(scope)] |> reject_unsafe_scope!()

  defp reject_unsafe_scope!(scope) do
    case Enum.find(scope, &(&1 in ["__proto__", "prototype", "constructor"])) do
      nil -> scope
      segment -> raise ArgumentError, "unsafe QuickBEAM API scope segment: #{inspect(segment)}"
    end
  end

  defp rollback_handlers(runtime, previous_handlers) do
    Runtime.replace_handlers(runtime, previous_handlers)
    invalidate_handler_cache()
  end

  defp invalidate_handler_cache do
    Heap.put_handler_globals(nil)
    :ok
  end
end
