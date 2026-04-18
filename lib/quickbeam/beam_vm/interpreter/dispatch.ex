defmodule QuickBEAM.BeamVM.Interpreter.Dispatch do
  @moduledoc false

  alias QuickBEAM.BeamVM.Bytecode
  alias QuickBEAM.BeamVM.Heap

  @doc "Call a JS callable value with args and optional this binding."
  def call_builtin({:builtin, _, cb}, args, this) when is_function(cb, 2), do: cb.(args, this)

  def call_builtin({:builtin, _, cb}, args, this) when is_function(cb, 3),
    do: cb.(args, this, self())

  def call_builtin({:builtin, _, cb}, args, _this) when is_function(cb, 1), do: cb.(args)
  def call_builtin({:bound, _, inner}, args, this), do: call_builtin(inner, args, this)
  def call_builtin(f, args, _this) when is_function(f), do: apply(f, args)

  def call_builtin(_, _, _),
    do: throw({:js_throw, Heap.make_error("not a function", "TypeError")})

  @doc "Check if a value is callable."
  def callable?(%Bytecode.Function{}), do: true
  def callable?({:closure, _, %Bytecode.Function{}}), do: true
  def callable?({:builtin, _, _}), do: true
  def callable?({:bound, _, _}), do: true
  def callable?(f) when is_function(f), do: true
  def callable?(_), do: false
end
