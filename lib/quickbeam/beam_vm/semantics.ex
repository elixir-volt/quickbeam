defmodule QuickBEAM.BeamVM.Semantics do
  @moduledoc false

  alias QuickBEAM.BeamVM.Names
  alias QuickBEAM.BeamVM.ObjectModel.{Class, Copy, Functions, Get, Put}

  defdelegate get_super(func), to: Class
  defdelegate coalesce_this_result(result, this_obj), to: Class
  defdelegate raw_function(fun), to: Class
  defdelegate define_class(ctor_closure, parent_ctor, class_name \\ nil), to: Class
  defdelegate check_ctor_return(val), to: Class
  defdelegate get_super_value(proto_obj, this_obj, key), to: Class
  defdelegate put_super_value(proto_obj, this_obj, key, val), to: Class

  defdelegate copy_data_properties(target, source), to: Copy
  defdelegate enumerable_string_props(source), to: Copy
  defdelegate spread_source_to_list(source), to: Copy
  defdelegate spread_target_to_list(target), to: Copy

  defdelegate length_of(value), to: Get
  defdelegate define_array_el(target, idx, val), to: Put

  def function_name(name_val), do: Functions.function_name(name_val)
  def rename_function(fun, name), do: Functions.rename(fun, name)
  def normalize_property_key(key), do: Names.normalize_property_key(key)
end
