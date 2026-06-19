defmodule QuickBEAM.VM.RuntimeState do
  @moduledoc "Scoped access to process-local VM runtime context state."

  alias QuickBEAM.VM.Heap

  @doc "Returns the current process-local VM context."
  def current, do: Heap.get_ctx()

  @doc "Returns the current process-local context, falling back to the supplied context."
  def current_or(ctx), do: current() || ctx

  @doc "Refreshes globals on the current process-local context or supplied fallback context."
  def refresh_globals(ctx), do: QuickBEAM.VM.GlobalEnvironment.refresh(current_or(ctx))

  @doc "Installs a process-local VM context."
  def install(ctx), do: Heap.put_ctx(ctx)

  @doc "Restores a previously captured context, clearing state when nil."
  def restore(nil), do: Heap.put_ctx(nil)
  def restore(ctx), do: Heap.put_ctx(ctx)

  @doc "Runs a function with a temporary process-local VM context."
  def with_context(ctx, fun) when is_function(fun, 0) do
    previous = current()
    install(ctx)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc "Returns the global/cache key for an interpreter arguments object."
  def arguments_object_key(current_func, arg_buf),
    do: {:qb_arguments_object, current_func, arg_buf}

  @doc "Returns the primary process-cache key for a compiled arguments object."
  def compiled_arguments_object_key(current_func, arg_buf),
    do: {:qb_compiled_arguments_object, current_func, arg_buf}

  @doc "Returns the fallback process-cache key for a compiled arguments object."
  def compiled_arguments_object_key(current_func),
    do: {:qb_compiled_arguments_object, current_func}

  @doc "Returns a cached arguments object for a process-local key."
  def get_arguments_object(key), do: Process.get(key)

  @doc "Caches an arguments object for one or more process-local keys."
  def put_arguments_object(keys, arguments) when is_list(keys) do
    Enum.each(keys, &Process.put(&1, arguments))
    arguments
  end

  def put_arguments_object(key, arguments) do
    Process.put(key, arguments)
    arguments
  end

  @doc "Stores the iterator that produced an iterator result object."
  def put_iterator_result_owner(result, iter_obj),
    do: Process.put({:qb_iterator_result_owner, result}, iter_obj)

  @doc "Returns the iterator that produced an iterator result object, when known."
  def get_iterator_result_owner(result), do: Process.get(iterator_result_owner_key(result))

  @doc "Consumes the iterator owner for an iterator result object, when known."
  def consume_iterator_result_owner(result), do: Process.delete(iterator_result_owner_key(result))

  defp iterator_result_owner_key(result), do: {:qb_iterator_result_owner, result}

  @doc "Runs a function while rooting values owned by a suspended interpreter frame."
  def with_suspended_roots(roots, fun) when is_list(roots) and is_function(fun, 0) do
    previous = Process.get(:qb_interpreter_suspended_roots, [])
    Process.put(:qb_interpreter_suspended_roots, roots ++ previous)

    try do
      fun.()
    after
      case previous do
        [] -> Process.delete(:qb_interpreter_suspended_roots)
        _ -> Process.put(:qb_interpreter_suspended_roots, previous)
      end
    end
  end
end
