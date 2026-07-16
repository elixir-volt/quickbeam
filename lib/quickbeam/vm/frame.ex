defmodule QuickBEAM.VM.Frame do
  @moduledoc "Defines an explicit JavaScript bytecode call frame."

  @enforce_keys [:function, :callable, :locals, :args]
  defstruct [
    :function,
    :callable,
    :locals,
    :args,
    :this,
    actual_arg_count: 0,
    closure_refs: {},
    compiler_allow_reentry: false,
    compiler_entered: false,
    compiler_reentry_after_instruction: false,
    pc: 0,
    stack: []
  ]

  @type t :: %__MODULE__{
          function: QuickBEAM.VM.Function.t(),
          callable: term(),
          closure_refs: tuple(),
          compiler_allow_reentry: boolean(),
          compiler_entered: boolean(),
          compiler_reentry_after_instruction: boolean(),
          locals: tuple(),
          args: tuple(),
          actual_arg_count: non_neg_integer(),
          this: term(),
          pc: non_neg_integer(),
          stack: [term()]
        }
end
