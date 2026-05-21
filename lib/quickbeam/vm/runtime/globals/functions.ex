defmodule QuickBEAM.VM.Runtime.Globals.Functions do
  @moduledoc "Implementations for global JavaScript functions such as `eval`, `require`, and `queueMicrotask`."

  alias QuickBEAM.VM.Execution.Eval
  alias QuickBEAM.VM.{Heap, RuntimeState}
  alias QuickBEAM.VM.JSThrow

  @doc "Implements global `eval` for source strings by compiling and evaluating them in the current runtime."
  def js_eval([code | _], _) when is_binary(code) do
    ctx = RuntimeState.current()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, value} <- Eval.compile_and_eval(pid, code) do
      value
    else
      %{runtime_pid: nil} -> eval_without_runtime(code)
      nil -> eval_without_runtime(code)
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      {:error, %{message: msg}} -> JSThrow.syntax_error!(msg)
      {:error, msg} when is_binary(msg) -> JSThrow.syntax_error!(msg)
      _ -> :undefined
    end
  end

  def js_eval(_, _), do: :undefined

  def js_eval_global([code | _], {:obj, ref}) when is_binary(code) do
    ctx = RuntimeState.current()
    globals = Heap.get_obj(ref, %{})
    pre_globals = Heap.get_persistent_globals()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, value} <- Eval.compile_and_eval(pid, code, globals: globals) do
      realm_updates = Heap.get_persistent_globals() || %{}
      Heap.put_persistent_globals(pre_globals)
      Heap.put_obj(ref, Map.merge(globals, realm_updates))
      value
    else
      {:error, {:js_throw, value}} -> throw({:js_throw, value})
      {:error, %{message: msg}} -> JSThrow.syntax_error!(msg)
      {:error, msg} when is_binary(msg) -> JSThrow.syntax_error!(msg)
      _ -> :undefined
    end
  end

  def js_eval_global(_, _), do: :undefined

  def decode_uri([value | _], _), do: URI.decode(to_string_value(value))
  def decode_uri(_, _), do: :undefined

  def decode_uri_component([value | _], _), do: URI.decode_www_form(to_string_value(value))
  def decode_uri_component(_, _), do: :undefined

  def encode_uri([value | _], _), do: URI.encode(to_string_value(value), &URI.char_unreserved?/1)
  def encode_uri(_, _), do: :undefined

  def encode_uri_component([value | _], _), do: URI.encode_www_form(to_string_value(value))
  def encode_uri_component(_, _), do: :undefined

  defp to_string_value(value), do: QuickBEAM.VM.Semantics.Values.stringify(value)

  defp eval_without_runtime(code) do
    task =
      Task.async(fn ->
        with {:ok, rt} <- QuickBEAM.start(apis: false) do
          try do
            QuickBEAM.eval(rt, code)
          after
            QuickBEAM.stop(rt)
          end
        end
      end)

    case Task.await(task, 5_000) do
      {:ok, value} -> value
      _ -> :undefined
    end
  rescue
    _ -> :undefined
  end

  @doc "Implements the CommonJS-like `require` global backed by registered VM modules."
  def js_require([name | _], _) do
    case Heap.get_module(name) do
      nil -> JSThrow.error!("Cannot find module '#{name}'")
      exports -> exports
    end
  end

  @doc "Implements `queueMicrotask` by enqueuing a callback in the VM microtask queue."
  def queue_microtask([callback | _], _) do
    unless QuickBEAM.VM.Builtin.callable?(callback) do
      JSThrow.type_error!(
        "Failed to execute 'queueMicrotask': The callback provided as parameter 1 is not a function."
      )
    end

    Heap.enqueue_microtask({:resolve, nil, callback, :undefined})
    :undefined
  end
end
