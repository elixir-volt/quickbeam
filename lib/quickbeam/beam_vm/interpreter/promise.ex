defmodule QuickBEAM.BeamVM.Interpreter.Promise do
  @moduledoc false

  alias QuickBEAM.BeamVM.PromiseState

  defdelegate resolved(val), to: PromiseState
  defdelegate rejected(val), to: PromiseState
  defdelegate resolve(ref, state, val), to: PromiseState
  defdelegate drain_microtasks(), to: PromiseState
end
