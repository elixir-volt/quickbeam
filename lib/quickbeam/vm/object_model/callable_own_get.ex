defmodule QuickBEAM.VM.ObjectModel.CallableOwnGet do
  @moduledoc "Own-property lookup for callable VM values."

  alias QuickBEAM.VM.ObjectModel.{BuiltinFunctionGet, FunctionExoticGet}

  def callable?(%QuickBEAM.VM.Function{}), do: true
  def callable?({:closure, _, %QuickBEAM.VM.Function{}}), do: true
  def callable?({:bound, _, _, _, _}), do: true
  def callable?({:builtin, _, _}), do: true
  def callable?(_), do: false

  def own_property({:builtin, _, _} = builtin, key, call_getter),
    do: BuiltinFunctionGet.own_property(builtin, key, call_getter)

  def own_property(%QuickBEAM.VM.Function{} = fun, key, call_getter),
    do: FunctionExoticGet.own_property(fun, key, call_getter)

  def own_property({:closure, _, %QuickBEAM.VM.Function{}} = closure, key, call_getter),
    do: FunctionExoticGet.own_property(closure, key, call_getter)

  def own_property({:bound, _, _, _, _} = bound, key, call_getter),
    do: FunctionExoticGet.own_property(bound, key, call_getter)
end
