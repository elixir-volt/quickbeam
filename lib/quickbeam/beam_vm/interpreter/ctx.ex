defmodule QuickBEAM.BeamVM.Interpreter.Ctx do
  @type t :: %__MODULE__{
          this: term(),
          arg_buf: tuple(),
          current_func: term(),
          catch_stack: [{non_neg_integer(), [term()]}],
          atoms: tuple(),
          globals: map()
        }

  defstruct this: :undefined,
            arg_buf: {},
            current_func: :undefined,
            catch_stack: [],
            atoms: {},
            globals: %{}
end
