defmodule QuickBEAM.VM.Interpreter.Ops.SuperProperties do
  @moduledoc "Interpreter helpers for super property lookup and assignment."

  alias QuickBEAM.VM.ObjectModel.Class

  def get(func, home_object, super_object) do
    if func == home_object, do: super_object, else: Class.get_super(func)
  end

  def get_value(proto, this_obj, key), do: Class.get_super_value(proto, this_obj, key)

  def put_value(proto_obj, this_obj, key, value),
    do: Class.put_super_value(proto_obj, this_obj, key, value)
end
