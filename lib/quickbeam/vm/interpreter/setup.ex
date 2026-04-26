defmodule QuickBEAM.VM.Interpreter.Setup do
  @moduledoc "Builds interpreter contexts and stores bytecode atom tables before execution."

  alias QuickBEAM.VM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.Invocation.Context, as: InvokeContext

  @doc "Builds the interpreter context used for evaluating decoded bytecode."
  def build_eval_context(opts, atoms, gas) do
    base_globals = Runtime.global_bindings()
    persistent = Heap.get_persistent_globals() |> Map.drop(Map.keys(base_globals))

    %Context{
      atoms: atoms,
      gas: gas,
      globals:
        base_globals
        |> Map.merge(persistent)
        |> Map.merge(Map.get(opts, :globals, %{})),
      runtime_pid: Map.get(opts, :runtime_pid),
      this: Map.get(opts, :this) || Map.get(base_globals, "globalThis", :undefined),
      arg_buf: Map.get(opts, :arg_buf, {}),
      current_func: Map.get(opts, :current_func, :undefined),
      new_target: Map.get(opts, :new_target, :undefined),
      trace_enabled: Map.get(opts, :trace_enabled, true)
    }
    |> InvokeContext.attach_method_state()
  end

  @doc "Stores atom tables for a function and all nested functions."
  def store_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Heap.put_fn_atoms(fun.byte_code, atoms)

    for %Bytecode.Function{} = inner <- fun.constants do
      store_function_atoms(inner, atoms)
    end

    :ok
  end
end
