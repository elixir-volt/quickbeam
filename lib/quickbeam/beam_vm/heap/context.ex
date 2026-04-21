defmodule QuickBEAM.BeamVM.Heap.Context do
  @moduledoc false

  alias QuickBEAM.BeamVM.Interpreter.Context

  def get_ctx do
    case Process.get(:qb_ctx, :__qb_missing__) do
      :__qb_missing__ ->
        case Process.get(:qb_fast_ctx, :__qb_missing__) do
          {atoms, globals, current_func, arg_buf, this, new_target, home_object, super} ->
            %Context{
              atoms: atoms,
              globals: globals,
              current_func: current_func,
              arg_buf: arg_buf,
              this: this,
              new_target: new_target,
              home_object: home_object,
              super: super
            }

          _ ->
            nil
        end

      ctx ->
        ctx
    end
  end

  def put_ctx(nil), do: Process.delete(:qb_ctx)
  def put_ctx(ctx), do: Process.put(:qb_ctx, ctx)

  def get_object_prototype, do: Process.get(:qb_object_prototype)
  def put_object_prototype(proto), do: Process.put(:qb_object_prototype, proto)

  def get_global_cache, do: Process.get(:qb_global_bindings_cache)
  def put_global_cache(bindings), do: Process.put(:qb_global_bindings_cache, bindings)

  def get_atoms, do: Process.get(:qb_atoms, {})
  def put_atoms(atoms), do: Process.put(:qb_atoms, atoms)

  def get_persistent_globals, do: Process.get(:qb_persistent_globals, %{})
  def put_persistent_globals(globals), do: Process.put(:qb_persistent_globals, globals)

  def get_handler_globals, do: Process.get(:qb_handler_globals)
  def put_handler_globals(globals), do: Process.put(:qb_handler_globals, globals)

  def get_runtime_mode(runtime), do: Process.get({:qb_runtime_mode, runtime})
  def put_runtime_mode(runtime, mode), do: Process.put({:qb_runtime_mode, runtime}, mode)
end
