defmodule QuickBEAM.BeamVM.Runtime.Property do
  @moduledoc "JS property resolution: own properties, prototype chain, getters."

  alias QuickBEAM.BeamVM.ObjectModel.Get

  defdelegate get(value, key), to: Get
  defdelegate call_getter(fun, this_obj), to: Get
  defdelegate regexp_flags(value), to: Get
  defdelegate string_length(value), to: Get
  defdelegate length_of(value), to: Get
end
