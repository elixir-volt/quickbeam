defmodule QuickBEAM.VM.Runtime.Globals.Functions do
  @moduledoc false

  alias QuickBEAM.VM.{Bytecode, Heap}
  alias QuickBEAM.VM.Interpreter
  alias QuickBEAM.VM.JSThrow
  alias QuickBEAM.VM.Runtime

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

  def js_require([name | _], _) do
    case Heap.get_module(name) do
      nil -> JSThrow.error!("Cannot find module '#{name}'")
      exports -> exports
    end
  end

  def queue_microtask([callback | _], _) do
    Heap.enqueue_microtask({:resolve, nil, callback, :undefined})
    :undefined
  end
end
