defmodule QuickBEAM.BeamVM.Interpreter.Setup do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap, Runtime}
  alias QuickBEAM.BeamVM.Interpreter.Context
  alias QuickBEAM.BeamVM.Invocation.Context, as: InvokeContext

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
      this: Map.get(opts, :this, :undefined),
      arg_buf: Map.get(opts, :arg_buf, {}),
      current_func: Map.get(opts, :current_func, :undefined),
      new_target: Map.get(opts, :new_target, :undefined)
    }
    |> InvokeContext.attach_method_state()
  end

  def store_function_atoms(%Bytecode.Function{} = fun, atoms) do
    Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

    for %Bytecode.Function{} = inner <- fun.constants do
      store_function_atoms(inner, atoms)
    end

    :ok
  end
end
