defmodule QuickBEAM.VM.Compiler.RuntimeABI.Bindings do
  @moduledoc false

  alias QuickBEAM.VM.GlobalEnvironment
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings, as: RuntimeBindings
  alias QuickBEAM.VM.ObjectModel.InternalMethods

  def get_var(ctx, name), do: RuntimeBindings.get_var(ctx, name)
  def get_var_undef(ctx, name), do: RuntimeBindings.get_var_undef(ctx, name)
  def get_global(ctx, name), do: get_global_binding_or_property(ctx, name, :throw)
  def get_global_undef(ctx, name), do: get_global_binding_or_property(ctx, name, :undefined)
  def get_var_ref(ctx, idx), do: RuntimeBindings.get_var_ref(ctx, idx)
  def get_var_ref_check(ctx, idx), do: RuntimeBindings.get_var_ref_check(ctx, idx)
  def put_var(ctx, atom_idx, value, opts), do: GlobalEnvironment.put(ctx, atom_idx, value, opts)
  def define_var(ctx, atom_idx, scope), do: GlobalEnvironment.define_var(ctx, atom_idx, scope)
  def check_define_var(ctx, atom_idx), do: GlobalEnvironment.check_define_var(ctx, atom_idx)
  def refresh_globals(ctx), do: GlobalEnvironment.refresh(ctx)
  def delete_var(ctx, atom_idx), do: RuntimeBindings.delete_var(ctx, atom_idx)
  def put_var_ref(ctx, idx, value), do: RuntimeBindings.put_var_ref(ctx, idx, value)

  def put_var_ref_check_init(ctx, idx, value),
    do: RuntimeBindings.put_var_ref_check_init(ctx, idx, value)

  def set_var_ref(ctx, idx, value), do: RuntimeBindings.set_var_ref(ctx, idx, value)
  def make_loc_ref(ctx, idx, value), do: RuntimeBindings.make_loc_ref(ctx, idx, value)
  def make_arg_ref(ctx, idx), do: RuntimeBindings.make_arg_ref(ctx, idx)
  def make_var_ref(ctx, atom_idx), do: RuntimeBindings.make_var_ref(ctx, atom_idx)
  def make_var_ref_ref(ctx, idx), do: RuntimeBindings.make_var_ref_ref(ctx, idx)
  def get_ref_value(ctx, key, ref), do: RuntimeBindings.get_ref_value(ctx, key, ref)
  def put_ref_value(ctx, value, key, ref), do: RuntimeBindings.put_ref_value(ctx, value, key, ref)

  defp get_global_binding_or_property(ctx, name, missing) do
    case fetch_global_binding(ctx.globals, name) do
      {:ok, :__tdz__} -> QuickBEAM.VM.JSThrow.reference_error!("#{name} is not initialized")
      {:ok, value} -> value
      :error -> get_global_object_property(ctx, name, missing)
    end
  end

  defp fetch_global_binding(globals, name) do
    persistent = QuickBEAM.VM.Heap.get_persistent_globals() || %{}

    if Map.has_key?(persistent, name) do
      Map.fetch(persistent, name)
    else
      Map.fetch(globals, name)
    end
  end

  defp get_global_object_property(ctx, name, missing) do
    case Map.get(ctx.globals, "globalThis") do
      {:obj, _} = global_this ->
        if InternalMethods.has_property(global_this, name) do
          InternalMethods.get(global_this, name)
        else
          missing_global!(name, missing)
        end

      _ ->
        missing_global!(name, missing)
    end
  end

  defp missing_global!(name, :throw),
    do: QuickBEAM.VM.JSThrow.reference_error!("#{name} is not defined")

  defp missing_global!(_name, :undefined), do: :undefined
end
