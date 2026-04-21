defmodule QuickBEAM.VM.Interpreter.Context do
  @moduledoc false
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
          gas: pos_integer()
        }

  @default_gas 1_000_000_000

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
            gas: @default_gas
end
