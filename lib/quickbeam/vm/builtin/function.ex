defmodule QuickBEAM.VM.Builtin.Function do
  @moduledoc "Defines declarative methods shared by JavaScript function objects."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Invocation

  builtin "Function",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object"] do
    prototype kind: :function,
              extends: "Object",
              default_for: :function,
              callable: :prototype_call do
      prototype_value "name", "", writable: false, configurable: true
      prototype_value "length", 0, writable: false, configurable: true
      method :bind, length: 1
      method :call, length: 1
    end
  end

  @doc "Rejects unsupported dynamic Function construction explicitly."
  def construct(%Call{execution: execution}),
    do: {:error, :dynamic_function_unsupported, execution}

  @doc "Implements the callable empty Function prototype object."
  def prototype_call(%Call{execution: execution}), do: {:ok, :undefined, execution}

  @doc "Creates a represented bound function."
  def bind(%Call{this: target, arguments: arguments, execution: execution}) do
    if Invocation.callable?(target, execution) do
      {bound_this, bound_arguments} =
        case arguments do
          [bound_this | rest] -> {bound_this, rest}
          [] -> {:undefined, []}
        end

      {:ok, {:bound_function, target, bound_this, bound_arguments}, execution}
    else
      {:error, :incompatible_function_receiver, execution}
    end
  end

  @doc "Invokes a function with an explicit receiver."
  def call(%Call{
        this: target,
        arguments: arguments,
        caller: caller,
        tail?: tail?,
        execution: execution
      }) do
    if Invocation.callable?(target, execution) do
      {this, arguments} =
        case arguments do
          [this | rest] -> {this, rest}
          [] -> {:undefined, []}
        end

      Builtin.action({:dispatch, target, arguments, this, caller, execution, tail?})
    else
      {:error, :incompatible_function_receiver, execution}
    end
  end
end
