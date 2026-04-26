defmodule QuickBEAM.VM.Runtime.Globals.Functions do
  @moduledoc "Implementations for global JavaScript functions such as `eval`, `require`, and `queueMicrotask`."

  alias QuickBEAM.VM.{Bytecode, Heap}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime

  @doc "Implements global `eval` for source strings by compiling and evaluating them in the current runtime."
  def js_eval([code | _], _) when is_binary(code) do
    ctx = Heap.get_ctx()

    with %{runtime_pid: pid} when pid != nil <- ctx,
         {:ok, bytecode} <- QuickBEAM.Runtime.compile(pid, code),
         {:ok, parsed} <- Bytecode.decode(bytecode),
         {:ok, value} <-
           Interpreter.eval(
             parsed.value,
             [],
             %{gas: Runtime.gas_budget(), runtime_pid: pid},
             parsed.atoms
           ) do
      value
    else
      %{runtime_pid: nil} -> :undefined
      nil -> :undefined
      {:error, %{message: msg}} -> JSThrow.syntax_error!(msg)
      {:error, msg} when is_binary(msg) -> JSThrow.syntax_error!(msg)
      _ -> :undefined
    end
  end

  def js_eval(_, _), do: :undefined

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
