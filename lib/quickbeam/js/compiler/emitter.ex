defmodule QuickBEAM.JS.Compiler.Emitter do
  @moduledoc false

  defstruct [:scope, :callbacks, instructions: [], constants: []]

  def new(scope, instructions \\ [], constants \\ [], callbacks \\ %{}) do
    %__MODULE__{
      scope: scope,
      instructions: instructions,
      constants: constants,
      callbacks: callbacks
    }
  end

  def result(%__MODULE__{instructions: instructions, constants: constants}),
    do: {:ok, instructions, constants}
end
