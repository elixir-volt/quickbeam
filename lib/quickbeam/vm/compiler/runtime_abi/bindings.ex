defmodule QuickBEAM.VM.Compiler.RuntimeABI.Bindings do
  @moduledoc false

  alias QuickBEAM.VM.GlobalEnvironment
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Bindings, as: RuntimeBindings

  def get_var(ctx, name), do: RuntimeBindings.get_var(ctx, name)
  def get_var_undef(ctx, name), do: RuntimeBindings.get_var_undef(ctx, name)
  def get_var_ref(ctx, idx), do: RuntimeBindings.get_var_ref(ctx, idx)
  def get_var_ref_check(ctx, idx), do: RuntimeBindings.get_var_ref_check(ctx, idx)
  def put_var(ctx, atom_idx, value, opts), do: GlobalEnvironment.put(ctx, atom_idx, value, opts)
  def define_var(ctx, atom_idx, scope), do: GlobalEnvironment.define_var(ctx, atom_idx, scope)
  def check_define_var(ctx, atom_idx), do: GlobalEnvironment.check_define_var(ctx, atom_idx)
  def refresh_globals(ctx), do: GlobalEnvironment.refresh(ctx)
  def delete_var(ctx, atom_idx), do: RuntimeBindings.delete_var(ctx, atom_idx)
  def put_var_ref(ctx, idx, value), do: RuntimeBindings.put_var_ref(ctx, idx, value)
  def set_var_ref(ctx, idx, value), do: RuntimeBindings.set_var_ref(ctx, idx, value)
  def make_loc_ref(ctx, idx, value), do: RuntimeBindings.make_loc_ref(ctx, idx, value)
  def make_arg_ref(ctx, idx), do: RuntimeBindings.make_arg_ref(ctx, idx)
  def make_var_ref(ctx, atom_idx), do: RuntimeBindings.make_var_ref(ctx, atom_idx)
  def make_var_ref_ref(ctx, idx), do: RuntimeBindings.make_var_ref_ref(ctx, idx)
  def get_ref_value(ctx, key, ref), do: RuntimeBindings.get_ref_value(ctx, key, ref)
  def put_ref_value(ctx, value, key, ref), do: RuntimeBindings.put_ref_value(ctx, value, key, ref)
end
