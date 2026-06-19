defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Context do
  @moduledoc "Context-shape helpers shared by compiler runtime support modules."

  alias QuickBEAM.VM.{GlobalEnvironment, Heap}
  alias QuickBEAM.VM.Interpreter.Context

  def struct_context(%Context{} = ctx), do: ctx

  def struct_context(map) when is_map(map) do
    struct(Context, Map.merge(Map.from_struct(%Context{}), map))
  end

  def atoms(%{atoms: atoms}), do: atoms
  def atoms(_), do: {}

  def globals(%{globals: globals}), do: globals
  def globals(_), do: GlobalEnvironment.base_globals()

  def current_func(%{current_func: current_func}), do: current_func
  def current_func(_), do: :undefined

  def arg_buf(%{arg_buf: arg_buf}), do: arg_buf
  def arg_buf(_), do: {}

  def this(%{this: this}), do: this
  def this(_), do: :undefined

  def new_target(%{new_target: new_target}), do: new_target
  def new_target(_), do: :undefined

  def gas(%{gas: gas}), do: gas
  def gas(_), do: Context.default_gas()

  def ensure(%Context{} = ctx), do: ctx
  def ensure(map) when is_map(map), do: struct_context(map)
  def ensure(_), do: %Context{atoms: Heap.get_atoms(), globals: GlobalEnvironment.base_globals()}
end
