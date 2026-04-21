defmodule QuickBEAM.BeamVM.Interpreter.Objects do
  @moduledoc false

  alias QuickBEAM.BeamVM.ObjectModel.Put

  defdelegate put(target, key, val), to: Put
  defdelegate put(target, key, val, enumerable), to: Put
  defdelegate put_getter(target, key, fun), to: Put
  defdelegate put_getter(target, key, fun, enumerable), to: Put
  defdelegate put_setter(target, key, fun), to: Put
  defdelegate put_setter(target, key, fun, enumerable), to: Put
  defdelegate has_property(target, key), to: Put
  defdelegate get_element(target, key), to: Put
  defdelegate put_element(target, key, val), to: Put
  defdelegate define_array_el(target, idx, val), to: Put
  defdelegate set_list_at(list, idx, val), to: Put
end
