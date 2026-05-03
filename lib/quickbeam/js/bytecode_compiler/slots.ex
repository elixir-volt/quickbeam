defmodule QuickBEAM.JS.BytecodeCompiler.Slots do
  @moduledoc false

  def read({:arg, index}), do: {:get_arg, index}
  def read({:loc, index}), do: {:get_loc, index}

  def write({:loc, index}), do: {:set_loc, index}
  def write({:arg, index}), do: {:set_arg, index}

  def put({:loc, index}), do: {:put_loc, index}
  def put({:arg, index}), do: {:put_arg, index}
end
