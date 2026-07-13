defmodule QuickBEAM.VM.Builtin do
  @moduledoc """
  Provides the runtime contract and `use` entry point for declarative builtins.

  `QuickBEAM.VM.Builtin.DSL` compiles declarations into immutable specs;
  `QuickBEAM.VM.Builtin.Validator` validates them; and
  `QuickBEAM.VM.Builtin.Installer` creates owner-local intrinsic objects.
  Runtime handlers receive an explicit `QuickBEAM.VM.Builtin.Call` and return an
  immediate result, JavaScript error, or typed resumable action.
  """

  alias QuickBEAM.VM.Builtin.{Action, Call, ContractError}
  alias QuickBEAM.VM.Execution

  @type handler_result ::
          {:ok, term(), Execution.t()}
          | {:error, term(), Execution.t()}
          | Action.t()

  @doc "Installs the declarative builtin DSL in a module."
  defmacro __using__(opts) do
    quote do
      use QuickBEAM.VM.Builtin.DSL, unquote(opts)
    end
  end

  @doc "Wraps a canonical resumable invocation action in the builtin result contract."
  @spec action(term()) :: Action.t()
  def action(value), do: %Action{value: value}

  @doc "Returns whether a declarative builtin token is its spec's constructor."
  @spec constructable?({:declared_builtin, module(), atom()}) :: boolean()
  def constructable?({:declared_builtin, module, handler}) do
    spec = module.builtin_spec()
    spec.kind == :constructor and spec.constructor == handler
  end

  @doc "Dispatches a stable token and validates the handler's runtime result."
  @spec invoke({:declared_builtin, module(), atom()}, Call.t()) :: handler_result()
  def invoke({:declared_builtin, module, handler}, %Call{} = call) do
    result = apply(module, handler, [call])

    case result do
      {:ok, _value, %Execution{}} -> result
      {:error, _reason, %Execution{}} -> result
      %Action{} -> result
      invalid -> raise ContractError, module: module, handler: handler, result: invalid
    end
  end
end
