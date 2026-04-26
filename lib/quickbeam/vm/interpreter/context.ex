defmodule QuickBEAM.VM.Interpreter.Context do
  @moduledoc "Execution context carried through interpreter evaluation and builtin invocation."
  @type t :: %__MODULE__{
          this: term(),
          arg_buf: tuple(),
          current_func: term(),
          home_object: term(),
          super: term(),
          catch_stack: [{non_neg_integer(), [term()]}],
          atoms: tuple(),
          globals: map(),
          runtime_pid: pid() | nil,
          new_target: term(),
          gas: pos_integer(),
          trace_enabled: boolean(),
          pd_synced: boolean()
        }

  @default_gas 1_000_000_000

  @doc "Returns the default gas budget for interpreter execution."
  def default_gas, do: @default_gas

  defstruct this: :undefined,
            arg_buf: {},
            current_func: :undefined,
            home_object: :undefined,
            super: :undefined,
            catch_stack: [],
            atoms: {},
            globals: %{},
            runtime_pid: nil,
            new_target: :undefined,
            gas: @default_gas,
            trace_enabled: false,
            pd_synced: false

  @doc "Marks a context as needing synchronization with process-local fast context state."
  def mark_dirty(%__MODULE__{} = ctx), do: %{ctx | pd_synced: false}
  @doc "Marks a context as synchronized with process-local fast context state."
  def mark_synced(%__MODULE__{} = ctx), do: %{ctx | pd_synced: true}
  @doc "Returns whether a context is synchronized with process-local fast context state."
  def synced?(%__MODULE__{pd_synced: synced?}), do: synced?
end
